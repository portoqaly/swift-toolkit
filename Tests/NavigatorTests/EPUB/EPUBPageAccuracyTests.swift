//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

enum EPUBPageAccuracyTests {
    @Test("the final viewport trailing edge reports terminal progression and position")
    static func finalViewportReportsCompletion() async {
        let readingOrder = [
            Link(href: "chapter-1.xhtml", mediaType: .html),
            Link(href: "chapter-2.xhtml", mediaType: .html),
        ]
        let positions = makePositions(resourceCount: 2, positionsPerResource: 4)

        let (locator, viewport) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: 1 ... 1,
            // The viewport top is only 75% through the resource, but its
            // trailing edge is physically at the publication end.
            progression: { _ in 0.75 ... 1.0 },
            readingOrder: readingOrder,
            positionsByReadingOrder: positions,
            tableOfContentsTitleByHref: [:],
            fallbackLocator: { _ in nil }
        )

        #expect(locator?.locations.totalProgression == 1.0)
        #expect(locator?.locations.position == 8)
        #expect(viewport.progression.upperBound == 1.0)
    }

    @Test("a viewport trailing edge at a non-final resource is not completion")
    static func intermediateViewportIsNotCompletion() async {
        let readingOrder = [
            Link(href: "chapter-1.xhtml", mediaType: .html),
            Link(href: "chapter-2.xhtml", mediaType: .html),
        ]
        let positions = makePositions(resourceCount: 2, positionsPerResource: 4)

        let (locator, _) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: 0 ... 0,
            progression: { _ in 0.75 ... 1.0 },
            readingOrder: readingOrder,
            positionsByReadingOrder: positions,
            tableOfContentsTitleByHref: [:],
            fallbackLocator: { _ in nil }
        )

        #expect(locator?.locations.totalProgression == 0.375)
        #expect(locator?.locations.position == 4)
    }

    private static func makePositions(
        resourceCount: Int,
        positionsPerResource: Int
    ) -> [[Locator]] {
        let total = resourceCount * positionsPerResource
        return (0 ..< resourceCount).map { resource in
            (0 ..< positionsPerResource).map { position in
                let absoluteIndex = resource * positionsPerResource + position
                return Locator(
                    href: AnyURL(string: "chapter-\(resource + 1).xhtml")!,
                    mediaType: .html,
                    locations: .init(
                        progression: Double(position) / Double(positionsPerResource - 1),
                        totalProgression: Double(absoluteIndex) / Double(total),
                        position: absoluteIndex + 1
                    )
                )
            }
        }
    }
}
