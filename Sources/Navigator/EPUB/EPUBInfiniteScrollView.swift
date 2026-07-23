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
        chapterCount = max(0, count)
        evictAll()
        guard chapterCount > 0 else { return }
        resetHeightIndex()
        currentIndex = max(0, min(index, chapterCount - 1))
        updateWindow(movingTo: location)
    }

    /// Scrolls (or jumps) to the chapter at `index`, positioning at `location`.
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< chapterCount ~= index else { return false }
        currentIndex = index
        let animated = options.animated && !UIAccessibility.isReduceMotionEnabled
        updateWindow(movingTo: location, animated: animated)
        return true
    }

    /// The spread view for the chapter currently in focus, if loaded.
    var currentView: EPUBSpreadView? { loadedViews[currentIndex] }

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
        measureContentHeight(of: spreadView, at: index)
    }

    /// Vertical scroll progression within the current chapter (0–1).
    var progressionInCurrentChapter: Double {
        let top = yOffset(for: currentIndex)
        let h = height(for: currentIndex)
        guard h > 0 else { return 0 }
        return min(1, max(0, Double((contentOffset.y - top) / h)))
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
    }

    // MARK: - Window Management

    private func updateWindow(movingTo location: PageLocation? = nil, animated: Bool = false) {
        guard chapterCount > 0 else { return }

        // Pixel-based window: chapters can be tiny (a 70px separator page) or huge
        // (a 15000px chapter), so a fixed chapter count either wastes memory or
        // lets the user scroll past the preloaded content and hit spinners.
        // Extend the window until it covers `preloadDistance` px in each direction,
        // with `preloadWindow` chapters as the minimum.
        let preloadDistance = max(bounds.height * 3, 2000)

        var lo = max(0, currentIndex - preloadWindow)
        var acc: CGFloat = (lo ..< currentIndex).reduce(0) { $0 + height(for: $1) }
        while lo > 0, acc < preloadDistance {
            lo -= 1
            acc += height(for: lo)
        }

        var hi = min(chapterCount - 1, currentIndex + preloadWindow)
        acc = 0
        if hi > currentIndex {
            for i in (currentIndex + 1) ... hi {
                acc += height(for: i)
            }
        }
        while hi < chapterCount - 1, acc < preloadDistance {
            hi += 1
            acc += height(for: hi)
        }

        // Evict out-of-window chapters
        for i in loadedViews.keys where !(lo ... hi ~= i) {
            loadedViews[i]?.removeFromSuperview()
            loadedViews.removeValue(forKey: i)
            heightObservations.removeValue(forKey: i)
        }

        // Load new chapters in the window
        for i in lo ... hi where loadedViews[i] == nil {
            guard let view = infiniteDelegate?.infiniteScrollView(self, spreadViewAtIndex: i) else { continue }
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

        if let location {
            scrollToChapter(currentIndex, location: location, animated: animated)
        }

        infiniteDelegate?.infiniteScrollViewDidUpdateViews(self)
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
                    let height = (result as? NSNumber).map({ CGFloat(truncating: $0) })
                else { return }
                self.applyMeasuredHeight(height, of: view, at: index)
            }
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
        chapterHeights.removeAll()
        chapterOffsets = [0]
        heightObservations.removeAll()
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

    private func scrollToChapter(_ index: Int, location: PageLocation, animated: Bool) {
        let top = yOffset(for: index)
        let h = height(for: index)
        let targetY: CGFloat

        switch location {
        case .start:
            targetY = top
        case .end:
            targetY = max(0, top + h - bounds.height)
        case .locator(let locator):
            let p = locator.locations.progression ?? 0
            targetY = top + h * CGFloat(p)
        }

        let maxY = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: min(max(0, targetY), maxY)), animated: animated)
    }

    // MARK: - Current Index Tracking

    private func refreshCurrentIndex() {
        guard chapterCount > 0, !isUpdatingGeometry else { return }
        let visibleIndex = index(at: contentOffset.y + 1)
        guard visibleIndex != currentIndex else { return }
        currentIndex = visibleIndex
        updateWindow()
    }
}

extension EPUBInfiniteScrollView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isUpdatingGeometry else { return }
        refreshCurrentIndex()
        infiniteDelegate?.infiniteScrollViewDidScroll(self)
    }
}
