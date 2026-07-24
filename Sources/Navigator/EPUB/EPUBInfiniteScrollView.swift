//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

@MainActor
protocol EPUBInfiniteScrollViewDelegate: AnyObject {
    /// Creates the spread view for the given reading-order index.
    func infiniteScrollView(_ view: EPUBInfiniteScrollView, spreadViewAtIndex index: Int) -> EPUBSpreadView?

    /// Called when the loaded views or current index changed.
    func infiniteScrollViewDidUpdateViews(_ view: EPUBInfiniteScrollView)

    /// Called as the continuous viewport moves within or between resources.
    func infiniteScrollViewDidScroll(_ view: EPUBInfiniteScrollView)
}

/// Renders EPUB chapters stacked vertically in a single continuous scroll.
///
/// Manages a sliding window of loaded `EPUBSpreadView` instances around the
/// current reading position. Chapters outside the window are evicted; placeholder
/// heights are used until each chapter's WebView reports its actual content height.
@MainActor
final class EPUBInfiniteScrollView: UIScrollView {
    weak var infiniteDelegate: EPUBInfiniteScrollViewDelegate?

    private(set) var chapterCount: Int = 0
    private(set) var currentIndex: Int = 0

    /// Loaded spread views indexed by reading-order position.
    private(set) var loadedViews: [Int: EPUBSpreadView] = [:]

    /// Actual content heights once each chapter's WebView has rendered.
    private var resolvedHeights: [Int: CGFloat] = [:]

    /// Resources whose DOM finished loading, even if their first intrinsic
    /// height probe raced WebKit and has not returned a usable value yet.
    private var readyResourceIndices: Set<Int> = []

    /// Intrinsic-height probes can transiently fail while WebKit is applying
    /// Readium CSS, fonts, or decorations. Retry with bounded backoff instead
    /// of leaving the resource permanently unresolved at a scroll boundary.
    private var measurementAttempts: [Int: Int] = [:]
    private let maximumMeasurementAttempts = 8

    /// Height and prefix-offset indexes for every reading-order resource.
    ///
    /// Keeping geometry for unloaded resources lets a fast fling resolve its
    /// destination without scanning only the currently materialized window.
    private var chapterHeights: [CGFloat] = []
    private var chapterOffsets: [CGFloat] = [0]

    /// KVO tokens observing each chapter's `webView.scrollView.contentSize`.
    private var heightObservations: [Int: NSKeyValueObservation] = [:]

    /// Chapters to preload on each side of the current one.
    private let preloadWindow = 2

    /// Hard upper bound for simultaneously retained resource WebViews.
    ///
    /// The pixel preload budget is useful for long chapters, but a book made
    /// of many tiny resources must not turn it into an unbounded WebView count.
    static let maximumLoadedResourceCount = 13

    /// Estimate used before a chapter's actual height is known.
    ///
    /// One viewport is deliberately conservative: it gives an unresolved
    /// chapter enough room to render and measure without creating a large
    /// artificial gap for short title/separator resources.
    private var placeholderHeight: CGFloat {
        max(1, bounds.height)
    }

    /// Prevents geometry corrections from recursively changing the active
    /// resource while `contentOffset` is being compensated.
    private var isUpdatingGeometry = false

    /// Prevents user-scroll loading guards from intercepting explicit locator
    /// navigation and geometry compensation.
    private var isProgrammaticNavigation = false
    private var isClampingUserScroll = false
    private var lastContentOffsetY: CGFloat = 0

    private struct PendingNavigation {
        let id = UUID()
        let index: Int
        let location: PageLocation
        let animated: Bool
        let completion: ((Bool) -> Void)?
    }

    /// Locator navigation waits for the destination DOM and intrinsic height.
    /// This is required for CSS selectors, fragments, and text-quote anchors;
    /// a placeholder-height percentage is not an exact destination.
    private var pendingNavigation: PendingNavigation?
    private var pendingNavigationTimeout: Task<Void, Never>?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        delegate = self
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        bounces = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        // Prevent inset from conflicting with the outer view controller's layout.
        insertSubview(UIView(frame: .zero), at: 0)
    }

    // MARK: - Public API

    /// Resets the view to display `count` chapters, positioning at `index`.
    func reload(at index: Int, location: PageLocation, count: Int) {
        cancelPendingNavigation()
        chapterCount = max(0, count)
        evictAll()
        guard chapterCount > 0 else { return }
        resetHeightIndex()
        currentIndex = max(0, min(index, chapterCount - 1))
        updateWindow()
        requestNavigation(to: currentIndex, location: location, animated: false)
    }

    /// Scrolls (or jumps) to the chapter at `index`, positioning at `location`.
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< chapterCount ~= index else { return false }
        cancelPendingNavigation()
        currentIndex = index
        let animated = options.animated && !UIAccessibility.isReduceMotionEnabled
        updateWindow()

        return await withCheckedContinuation { continuation in
            requestNavigation(
                to: index,
                location: location,
                animated: animated,
                completion: { continuation.resume(returning: $0) }
            )
        }
    }

    /// The spread view for the chapter currently in focus, if loaded.
    var currentView: EPUBSpreadView? {
        loadedViews[currentIndex]
    }

    /// Re-measures a resource once Readium has finished loading and applying
    /// its decoration scripts.
    ///
    /// `WKWebView.scrollView.contentSize` is not a reliable initial signal in
    /// this layout because the web view already has its placeholder frame by
    /// the time observation starts. The explicit load callback guarantees that
    /// every materialized resource gets one measurement with a ready DOM.
    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) {
        guard
            let index = loadedViews.first(where: { $0.value === spreadView })?.key
        else { return }
        markResourceReady(at: index)
        measureContentHeight(of: spreadView, at: index)
    }

    /// Marks a resource as safe for direct-manipulation scrolling once its DOM
    /// is ready. Internal so the boundary-unblocking contract can be tested
    /// without constructing a WebView.
    func markResourceReady(at index: Int) {
        guard 0 ..< chapterCount ~= index else { return }
        readyResourceIndices.insert(index)
    }

    /// Vertical scroll progression within the current chapter (0–1).
    var progressionInCurrentChapter: Double {
        progression(in: currentIndex).lowerBound
    }

    /// Reading-order resources intersecting the native viewport.
    var visibleReadingOrderRange: ClosedRange<Int> {
        guard chapterCount > 0 else { return 0 ... 0 }
        let first = index(at: contentOffset.y + 1)
        let last = index(at: contentOffset.y + max(1, bounds.height) - 1)
        return min(first, last) ... max(first, last)
    }

    /// Visible progression range within one resource.
    func progression(in index: Int) -> ClosedRange<Double> {
        let top = yOffset(for: index)
        let resourceHeight = height(for: index)
        guard resourceHeight > 0 else { return 0 ... 0 }

        let viewportTop = contentOffset.y
        let viewportBottom = contentOffset.y + bounds.height
        let first = min(1, max(0, Double((viewportTop - top) / resourceHeight)))
        let last = min(1, max(first, Double((viewportBottom - top) / resourceHeight)))
        return first ... last
    }

    /// Offset of the visible viewport within `index`, used for DOM locators.
    func visibleOffset(in index: Int) -> CGFloat {
        max(0, contentOffset.y - yOffset(for: index))
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard chapterCount > 0 else { return }

        let w = bounds.width
        for i in 0 ..< chapterCount {
            let h = height(for: i)
            loadedViews[i]?.frame = CGRect(x: 0, y: yOffset(for: i), width: w, height: h)
        }
        contentSize = CGSize(width: w, height: chapterOffsets.last ?? 0)
        updateAccessibilityVisibility()
    }

    // MARK: - Window Management

    private func updateWindow() {
        guard chapterCount > 0 else { return }

        let range = loadingRange(around: currentIndex)
        let lo = range.lowerBound
        let hi = range.upperBound

        // Evict out-of-window chapters
        for i in loadedViews.keys where !(lo ... hi ~= i) {
            loadedViews[i]?.removeFromSuperview()
            loadedViews.removeValue(forKey: i)
            heightObservations.removeValue(forKey: i)
            readyResourceIndices.remove(i)
            measurementAttempts.removeValue(forKey: i)
        }

        // Load new chapters in the window
        for i in lo ... hi where loadedViews[i] == nil {
            guard let view = infiniteDelegate?.infiniteScrollView(self, spreadViewAtIndex: i) else { continue }
            readyResourceIndices.remove(i)
            measurementAttempts[i] = 0
            prepareForInfiniteScroll(view)
            loadedViews[i] = view
            addSubview(view)
            observeContentHeight(of: view, at: i)

            // Body can resize after load (CSS injection, font loading) without
            // any contentSize KVO signal — the viewport pins contentSize to the
            // frame height. A ResizeObserver in the page reports those changes.
            view.registerJSMessage(named: "bodyResized") { [weak self, weak view] body in
                DispatchQueue.main.async {
                    guard let self, let view else { return }
                    if let height = (body as? NSNumber).map({ CGFloat(truncating: $0) }) {
                        self.applyMeasuredHeight(height, of: view, at: i)
                    } else {
                        self.measureContentHeight(of: view, at: i)
                    }
                }
            }
        }

        setNeedsLayout()
        layoutIfNeeded()

        infiniteDelegate?.infiniteScrollViewDidUpdateViews(self)
    }

    /// Computes the pixel-budgeted, count-bounded loading window.
    ///
    /// Internal so memory behavior can be verified without constructing
    /// WebViews in unit tests.
    func loadingRange(around index: Int) -> ClosedRange<Int> {
        guard chapterCount > 0 else { return 0 ... 0 }

        let center = max(0, min(index, chapterCount - 1))
        let preloadDistance = max(bounds.height * 3, 2000)
        let maximumSideCount = (Self.maximumLoadedResourceCount - 1) / 2

        let minimumLowerBound = max(0, center - maximumSideCount)
        var lo = max(minimumLowerBound, center - preloadWindow)
        var distance: CGFloat = (lo ..< center).reduce(0) { $0 + height(for: $1) }
        while lo > minimumLowerBound, distance < preloadDistance {
            lo -= 1
            distance += height(for: lo)
        }

        let maximumUpperBound = min(chapterCount - 1, center + maximumSideCount)
        var hi = min(maximumUpperBound, center + preloadWindow)
        distance = 0
        if hi > center {
            for i in (center + 1) ... hi {
                distance += height(for: i)
            }
        }
        while hi < maximumUpperBound, distance < preloadDistance {
            hi += 1
            distance += height(for: hi)
        }

        return lo ... hi
    }

    /// Disables the WebView's own scrolling so the outer scroll handles everything.
    private func prepareForInfiniteScroll(_ view: EPUBSpreadView) {
        view.webView.scrollView.isScrollEnabled = false
        view.webView.scrollView.showsVerticalScrollIndicator = false
        view.webView.scrollView.bounces = false
        view.webView.scrollView.contentInset = .zero
        view.webView.scrollView.contentOffset = .zero
    }

    // MARK: - Height Detection

    private func observeContentHeight(of view: EPUBSpreadView, at index: Int) {
        // `scrollView.contentSize` is circular in this mode: the `<html>` element
        // always stretches to the viewport (= the frame WE set), so contentSize
        // never reports a height smaller than the current frame. We only use the
        // KVO as a "layout changed" signal, then measure the real content extent
        // with JS (`document.body.scrollHeight` is independent of viewport height).
        let obs = view.webView.scrollView.observe(\.contentSize, options: .new) { [weak self, weak view] _, change in
            let signal = change.newValue?.height ?? 0
            // Ignore initial zero/tiny values before content renders
            guard signal > 100 else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, let view else { return }
                self.measureContentHeight(of: view, at: index)
            }
        }
        heightObservations[index] = obs
    }

    private func measureContentHeight(of view: EPUBSpreadView, at index: Int) {
        let js = """
        (function() {
            var b = document.body;
            if (!b) return 0;
            function intrinsicHeight() {
                var bodyRect = b.getBoundingClientRect();
                var cs = getComputedStyle(b);
                var top = bodyRect.top;
                var bottom = top;
                var range = document.createRange();
                range.selectNodeContents(b);
                Array.prototype.forEach.call(range.getClientRects(), function(rect) {
                    bottom = Math.max(bottom, rect.bottom);
                });
                Array.prototype.forEach.call(b.children, function(child) {
                    Array.prototype.forEach.call(child.getClientRects(), function(rect) {
                        bottom = Math.max(bottom, rect.bottom);
                    });
                });
                return Math.ceil(Math.max(0, bottom - top)
                    + (parseFloat(cs.paddingBottom) || 0)
                    + (parseFloat(cs.marginTop) || 0)
                    + (parseFloat(cs.marginBottom) || 0));
            }
            function reportHeight() {
                try {
                    webkit.messageHandlers.bodyResized.postMessage(intrinsicHeight());
                } catch (e) {}
            }
            if (!window.__rdrResizeObs__ && window.ResizeObserver) {
                window.__rdrResizeObs__ = new ResizeObserver(reportHeight);
                window.__rdrResizeObs__.observe(b);
                Array.prototype.forEach.call(b.children, function(child) {
                    window.__rdrResizeObs__.observe(child);
                });
            }
            if (!window.__rdrMutationObs__ && window.MutationObserver) {
                window.__rdrMutationObs__ = new MutationObserver(function() {
                    if (window.__rdrResizeObs__) {
                        Array.prototype.forEach.call(b.children, function(child) {
                            window.__rdrResizeObs__.observe(child);
                        });
                    }
                    reportHeight();
                });
                window.__rdrMutationObs__.observe(b, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
            }
            if (!window.__rdrFontsObserved__ && document.fonts) {
                window.__rdrFontsObserved__ = true;
                document.fonts.ready.then(reportHeight);
                document.fonts.addEventListener("loadingdone", reportHeight);
            }
            return intrinsicHeight();
        })()
        """
        view.webView.evaluateJavaScript(js) { [weak self, weak view] result, _ in
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    let view,
                    self.loadedViews[index] === view
                else { return }

                if
                    let height = (result as? NSNumber).map({ CGFloat(truncating: $0) }),
                    height > 20
                {
                    self.measurementAttempts.removeValue(forKey: index)
                    self.applyMeasuredHeight(height, of: view, at: index)
                } else {
                    self.scheduleMeasurementRetry(of: view, at: index)
                }
            }
        }
    }

    private func scheduleMeasurementRetry(of view: EPUBSpreadView, at index: Int) {
        guard
            loadedViews[index] === view,
            resolvedHeights[index] == nil
        else { return }

        let attempt = (measurementAttempts[index] ?? 0) + 1
        guard attempt <= maximumMeasurementAttempts else { return }
        measurementAttempts[index] = attempt

        // 0.1, 0.2, 0.4, 0.8, then 1.6 seconds. Eight attempts cover more
        // than seven seconds of slow CSS/font/decorations work without polling
        // forever when a malformed resource never produces a body.
        let delay = min(1.6, 0.1 * pow(2, Double(attempt - 1)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
            guard
                let self,
                let view,
                self.loadedViews[index] === view,
                self.resolvedHeights[index] == nil
            else { return }
            self.measureContentHeight(of: view, at: index)
        }
    }

    private func applyMeasuredHeight(_ measuredHeight: CGFloat, of view: EPUBSpreadView, at index: Int) {
        // Threshold only filters pre-render readings (body missing -> 0).
        // Real resources can be tiny (for example, a separator page).
        let height = ceil(measuredHeight)
        guard
            height > 20,
            loadedViews[index] === view,
            chapterHeights.indices.contains(index),
            resolvedHeights[index] != height
        else { return }

        let anchorIndex = self.index(at: contentOffset.y + 1)
        resolvedHeights[index] = height
        guard let delta = setHeight(height, at: index) else { return }

        isUpdatingGeometry = true
        setNeedsLayout()
        layoutIfNeeded()

        // Preserve the same document pixel when a resource above the viewport
        // resolves. The current resource needs no correction: its DOM origin
        // remains fixed while its frame grows or shrinks around the content.
        if index < anchorIndex, delta != 0 {
            var offset = contentOffset
            offset.y = max(0, offset.y + delta)
            contentOffset = offset
        }
        isUpdatingGeometry = false
        refreshCurrentIndex()
        resumePendingNavigationIfReady(for: index)

        // A measurement can land mid-reflow (CSS injection or font loading).
        // A stable verification pass is a no-op and cannot loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
            guard let self, let view, self.loadedViews[index] === view else { return }
            self.measureContentHeight(of: view, at: index)
        }
    }

    private func evictAll() {
        loadedViews.values.forEach { $0.removeFromSuperview() }
        loadedViews.removeAll()
        resolvedHeights.removeAll()
        readyResourceIndices.removeAll()
        measurementAttempts.removeAll()
        chapterHeights.removeAll()
        chapterOffsets = [0]
        heightObservations.removeAll()
    }

    // MARK: - Navigation

    private func requestNavigation(
        to index: Int,
        location: PageLocation,
        animated: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let navigation = PendingNavigation(
            index: index,
            location: location,
            animated: animated,
            completion: completion
        )
        pendingNavigation = navigation
        resumePendingNavigationIfReady(for: index)

        guard pendingNavigation?.id == navigation.id else { return }
        pendingNavigationTimeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self, self.pendingNavigation?.id == navigation.id else { return }
            self.pendingNavigation = nil
            self.pendingNavigationTimeout = nil
            navigation.completion?(false)
        }
    }

    private func resumePendingNavigationIfReady(for index: Int) {
        guard
            let navigation = pendingNavigation,
            navigation.index == index,
            canResolve(navigation.location, at: index)
        else { return }

        Task { [weak self] in
            await self?.completePendingNavigation(id: navigation.id)
        }
    }

    private func canResolve(_ location: PageLocation, at index: Int) -> Bool {
        switch location {
        case .start:
            return true
        case .end, .locator:
            return resolvedHeights[index] != nil
                && loadedViews[index]?.isSpreadLoaded == true
        }
    }

    private func completePendingNavigation(id: UUID) async {
        guard let navigation = pendingNavigation, navigation.id == id else { return }
        let targetY = await targetOffset(
            for: navigation.location,
            at: navigation.index
        )
        guard pendingNavigation?.id == id else { return }

        pendingNavigation = nil
        pendingNavigationTimeout?.cancel()
        pendingNavigationTimeout = nil
        performProgrammaticScroll(to: targetY, animated: navigation.animated)
        navigation.completion?(true)
    }

    private func targetOffset(for location: PageLocation, at index: Int) async -> CGFloat {
        let top = yOffset(for: index)
        let resourceHeight = height(for: index)
        let targetY: CGFloat

        switch location {
        case .start:
            targetY = top

        case .end:
            targetY = top + resourceHeight - bounds.height

        case let .locator(locator):
            if
                let view = loadedViews[index],
                let offset = await view.verticalOffset(for: locator)
            {
                targetY = top + offset
            } else {
                let progression = locator.locations.progression ?? 0
                targetY = top + resourceHeight * CGFloat(progression)
            }
        }

        let maxY = max(0, contentSize.height - bounds.height)
        return min(max(0, targetY), maxY)
    }

    private func performProgrammaticScroll(to targetY: CGFloat, animated: Bool) {
        let target = CGPoint(x: 0, y: targetY)
        let willAnimate = animated && abs(contentOffset.y - targetY) > 0.5
        isProgrammaticNavigation = true
        setContentOffset(target, animated: willAnimate)
        if !willAnimate {
            isProgrammaticNavigation = false
        }
        lastContentOffsetY = targetY
    }

    private func cancelPendingNavigation() {
        let completion = pendingNavigation?.completion
        pendingNavigation = nil
        pendingNavigationTimeout?.cancel()
        pendingNavigationTimeout = nil
        completion?(false)
    }

    // MARK: - Geometry

    private func height(for index: Int) -> CGFloat {
        guard chapterHeights.indices.contains(index) else {
            return placeholderHeight
        }
        return chapterHeights[index]
    }

    /// Returns the Y offset of the top of chapter `index`.
    func yOffset(for index: Int) -> CGFloat {
        guard chapterOffsets.indices.contains(index) else {
            return chapterOffsets.last ?? 0
        }
        return chapterOffsets[index]
    }

    private func resetHeightIndex() {
        chapterHeights = Array(repeating: placeholderHeight, count: chapterCount)
        rebuildOffsets()
    }

    private func rebuildOffsets() {
        chapterOffsets = [0]
        chapterOffsets.reserveCapacity(chapterHeights.count + 1)
        for height in chapterHeights {
            chapterOffsets.append((chapterOffsets.last ?? 0) + height)
        }
    }

    /// Updates one resource height and rebuilds the prefix index.
    ///
    /// Internal so the geometry can be covered without constructing WebViews.
    @discardableResult
    func setHeight(_ height: CGFloat, at index: Int) -> CGFloat? {
        guard height > 0, chapterHeights.indices.contains(index) else {
            return nil
        }
        let delta = height - chapterHeights[index]
        chapterHeights[index] = height
        rebuildOffsets()
        return delta
    }

    /// Returns the resource whose vertical interval contains `y`.
    func index(at y: CGFloat) -> Int {
        guard chapterCount > 0 else { return 0 }
        let target = max(0, min(y, max(0, (chapterOffsets.last ?? 0) - 1)))
        var lower = 0
        var upper = chapterCount

        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if chapterOffsets[middle + 1] <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, chapterCount - 1)
    }

    // MARK: - Current Index Tracking

    private func refreshCurrentIndex() {
        guard chapterCount > 0, !isUpdatingGeometry else { return }
        let visibleIndex = index(at: contentOffset.y + 1)
        guard visibleIndex != currentIndex else { return }
        currentIndex = visibleIndex
        updateWindow()
    }

    /// Stops a gesture at the first unresolved resource instead of letting a
    /// fling travel through placeholder geometry for the whole publication.
    private func clampUserScrollIfNeeded() -> Bool {
        guard
            !isUpdatingGeometry,
            !isProgrammaticNavigation,
            !isClampingUserScroll,
            chapterCount > 0
        else { return false }

        let y = contentOffset.y
        let targetIndex = index(at: y + 1)
        let movingDown = y > lastContentOffsetY
        let blocker: Int?

        if movingDown {
            if resourceRequiresLoad(at: currentIndex) {
                blocker = currentIndex
            } else if targetIndex > currentIndex {
                blocker = ((currentIndex + 1) ... targetIndex)
                    .first { resourceRequiresLoad(at: $0) }
            } else {
                blocker = nil
            }
        } else if targetIndex < currentIndex {
            blocker = (targetIndex ..< currentIndex)
                .reversed()
                .first { resourceRequiresLoad(at: $0) }
        } else {
            blocker = nil
        }

        guard let blocker else { return false }

        let clampedY: CGFloat = movingDown
            ? yOffset(for: blocker)
            : max(0, yOffset(for: blocker + 1) - bounds.height)

        isClampingUserScroll = true
        contentOffset.y = clampedY
        currentIndex = blocker
        updateWindow()
        isClampingUserScroll = false
        lastContentOffsetY = clampedY
        return true
    }

    /// A loaded DOM is safe to enter while its intrinsic-height probe retries.
    /// The guard only blocks flings across resources which have not loaded yet.
    func resourceRequiresLoad(at index: Int) -> Bool {
        resolvedHeights[index] == nil && !readyResourceIndices.contains(index)
    }

    private func updateAccessibilityVisibility() {
        let accessibilityRect = CGRect(
            x: 0,
            y: contentOffset.y - bounds.height,
            width: bounds.width,
            height: bounds.height * 3
        )
        for view in loadedViews.values {
            view.accessibilityElementsHidden = !view.frame.intersects(accessibilityRect)
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let delta: CGFloat
        switch direction {
        case .down:
            delta = bounds.height
        case .up:
            delta = -bounds.height
        default:
            return super.accessibilityScroll(direction)
        }

        let oldY = contentOffset.y
        let maxY = max(0, contentSize.height - bounds.height)
        let newY = min(max(0, oldY + delta), maxY)
        guard abs(newY - oldY) > 0.5 else { return false }

        setContentOffset(CGPoint(x: 0, y: newY), animated: !UIAccessibility.isReduceMotionEnabled)
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}

extension EPUBInfiniteScrollView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isUpdatingGeometry, !isClampingUserScroll else { return }
        if clampUserScrollIfNeeded() {
            infiniteDelegate?.infiniteScrollViewDidScroll(self)
            return
        }
        refreshCurrentIndex()
        updateAccessibilityVisibility()
        lastContentOffsetY = contentOffset.y
        infiniteDelegate?.infiniteScrollViewDidScroll(self)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isProgrammaticNavigation = false
        lastContentOffsetY = contentOffset.y
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isProgrammaticNavigation = false
        lastContentOffsetY = contentOffset.y
    }
}
