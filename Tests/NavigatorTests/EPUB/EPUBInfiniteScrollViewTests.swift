//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import UIKit

@MainActor
@Suite("EPUB continuous scroll geometry")
struct EPUBInfiniteScrollViewTests {
    private func makeView(chapterCount: Int = 100) -> EPUBInfiniteScrollView {
        let view = EPUBInfiniteScrollView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800)
        )
        view.reload(at: 0, location: .start, count: chapterCount)
        return view
    }

    @Test("unresolved resources reserve one viewport instead of a fixed gap")
    func viewportSizedEstimates() {
        let view = makeView(chapterCount: 4)

        #expect(view.yOffset(for: 0) == 0)
        #expect(view.yOffset(for: 1) == 800)
        #expect(view.yOffset(for: 4) == 3200)
        #expect(view.contentSize.height == 3200)
    }

    @Test("resolved heights rebuild every following resource offset")
    func resolvedHeightPrefixIndex() {
        let view = makeView(chapterCount: 4)

        #expect(view.setHeight(200, at: 0) == -600)
        #expect(view.setHeight(1200, at: 1) == 400)

        #expect(view.yOffset(for: 1) == 200)
        #expect(view.yOffset(for: 2) == 1400)
        #expect(view.yOffset(for: 3) == 2200)
        #expect(view.yOffset(for: 4) == 3000)
    }

    @Test("resource lookup honors exact height boundaries")
    func resourceLookupBoundaries() {
        let view = makeView(chapterCount: 4)
        view.setHeight(200, at: 0)
        view.setHeight(1200, at: 1)

        #expect(view.index(at: -1) == 0)
        #expect(view.index(at: 199) == 0)
        #expect(view.index(at: 200) == 1)
        #expect(view.index(at: 1399) == 1)
        #expect(view.index(at: 1400) == 2)
        #expect(view.index(at: .greatestFiniteMagnitude) == 3)
    }

    @Test("a fast fling preserves direct manipulation across unresolved resources")
    func fastFlingPreservesMomentumDestination() {
        let view = makeView()
        view.contentOffset.y = 80 * 800 + 10
        view.scrollViewDidScroll(view)

        #expect(view.currentIndex == 80)
        #expect(view.contentOffset.y == 80 * 800 + 10)
    }

    @Test("an unresolved adjacent resource never clamps a user's drag")
    func unresolvedBoundaryDoesNotClamp() {
        let view = makeView(chapterCount: 2)
        view.setHeight(1200, at: 0)

        view.contentOffset.y = 1200
        view.scrollViewDidScroll(view)

        #expect(view.currentIndex == 1)
        #expect(view.contentOffset.y == 1200)
    }

    @Test("the loading window has a hard WebView-count bound")
    func loadingWindowIsBounded() {
        let view = makeView()
        for index in 0 ..< 100 {
            view.setHeight(40, at: index)
        }

        let range = view.loadingRange(around: 50)
        #expect(range.count == EPUBInfiniteScrollView.maximumLoadedResourceCount)
        #expect(range == 44 ... 56)
    }

    @Test("visible progressions include every resource crossing the viewport")
    func visibleProgressionRanges() {
        let view = makeView(chapterCount: 3)
        view.setHeight(200, at: 0)
        view.setHeight(1200, at: 1)

        #expect(view.visibleReadingOrderRange == 0 ... 1)
        #expect(view.progression(in: 0) == 0 ... 1)
        #expect(view.progression(in: 1) == 0 ... 0.5)
    }
}
