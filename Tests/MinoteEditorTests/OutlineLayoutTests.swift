import CoreGraphics
import Testing
@testable import MinoteEditor

/// The overlay's area: a strip at the page's right edge, below the toolbar.
private let strip = CGRect(x: 0, y: 0, width: 320, height: 700)

private func layout(_ levels: [Int], textMaxX: CGFloat = 0, bounds: CGRect = strip, anchor: Int? = nil) -> OutlineLayout {
    OutlineLayout(levels: levels, bounds: bounds, textMaxX: textMaxX, anchor: anchor)
}

@Suite("Outline layout")
struct OutlineLayoutTests {
    @Test func dashesSitRightAlignedAndCenteredByLevel() {
        let outline = layout([1, 2, 2, 3, 1])
        #expect(!outline.isHidden)
        #expect(outline.dashScale == 1)
        #expect(outline.dashRange == 0..<5)
        #expect(outline.dashSpacing == OutlineLayout.maxDashSpacing)
        #expect(outline.railRight == 310)
        #expect((0..<5).map(outline.dashWidth) == [18, 13, 13, 9, 18])
        #expect((0..<5).map { outline.dashRect($0).maxX } == Array(repeating: 310, count: 5))
        // Centered between the reserves (12 above and below).
        #expect(outline.railCenterY == 350)
        #expect(outline.dashY(0) == 330)
        #expect(outline.dashY(4) == 370)
        #expect(outline.railHitRect.contains(CGPoint(x: 300, y: 350)))
        #expect(!outline.railHitRect.contains(CGPoint(x: 300, y: 300)))
    }

    @Test func hiddenWithoutHeadingsOrRoom() {
        #expect(layout([1]).isHidden)
        #expect(layout([]).isHidden)
        #expect(layout([1, 2], textMaxX: 305).isHidden)
        #expect(layout([1, 2], bounds: CGRect(x: 0, y: 0, width: 320, height: 50)).isHidden)
    }

    @Test func narrowMarginsShrinkTheDashesClearOfTheText() {
        let outline = layout([1, 2, 3], textMaxX: 296)
        #expect(!outline.isHidden)
        #expect(outline.dashScale < 1)
        for index in 0..<3 {
            #expect(outline.dashRect(index).minX >= 296 + 10)
            #expect(outline.dashRect(index).maxX <= strip.maxX)
        }
    }

    @Test func longOutlinesPackTheirDashesThenShowAWindow() {
        let sixty = layout(Array(repeating: 2, count: 60))
        #expect(sixty.dashSpacing < OutlineLayout.maxDashSpacing)
        #expect(sixty.dashSpacing >= OutlineLayout.minDashSpacing)
        #expect(sixty.dashRange == 0..<60)
        #expect(sixty.railRect.height <= (strip.height - 24) * 0.7 + OutlineLayout.dashThickness)

        let long = layout(Array(repeating: 2, count: 300), anchor: 150)
        #expect(long.dashSpacing == OutlineLayout.minDashSpacing)
        #expect(long.dashRange.count < 300)
        #expect(long.dashRange.contains(150))
        #expect(long.dashOpacity(150) == 1)
        #expect(long.dashOpacity(long.dashRange.lowerBound) < 1)
        #expect(long.dashOpacity(long.dashRange.upperBound - 1) < 1)
        #expect(long.dashOpacity(0) == 0)
        // Headings past the window gather at its ends.
        #expect(long.dashY(0) == long.dashY(long.dashRange.lowerBound))

        let atStart = layout(Array(repeating: 2, count: 300), anchor: 0)
        #expect(atStart.dashRange.lowerBound == 0)
        #expect(atStart.dashOpacity(0) == 1)
    }

    @Test func theCardIsCenteredOnTheRailInsideThePage() {
        let outline = layout([1, 2, 2, 3, 1])
        let card = outline.cardRect
        #expect(card.width == OutlineLayout.cardMaxWidth)
        #expect(card.maxX == 318)
        #expect(card.height == 5 * OutlineLayout.rowHeight + 2 * OutlineLayout.cardPadding)
        #expect(card.midY == outline.railCenterY)
        #expect(outline.maxListOffset == 0)
        #expect(outline.listOffset(placing: 4) == 0)
        // The card covers the rail, so the rail morphs inside it.
        #expect(card.contains(outline.railRect))
    }

    @Test func rowsAndTheirHitTestsAgree() {
        let outline = layout([1, 2, 2, 3, 1])
        for index in 0..<5 {
            let row = outline.rowRect(index, listOffset: 0)
            #expect(outline.rowIndex(at: CGPoint(x: row.midX, y: row.midY), listOffset: 0) == index)
            #expect(outline.textRect(index, listOffset: 0).minX > outline.dotRect(index, listOffset: 0).maxX)
        }
        // Deeper headings are indented.
        #expect(outline.textRect(1, listOffset: 0).minX > outline.textRect(0, listOffset: 0).minX)
        #expect(outline.rowIndex(at: CGPoint(x: 10, y: 350), listOffset: 0) == nil)
        #expect(outline.visibleRows(listOffset: 0) == 0..<5)
        #expect(outline.dashIndex(near: 331) == 0)
        #expect(outline.dashIndex(near: 349) == 2)
        #expect(outline.dashIndex(near: 1_000) == 4)
    }

    @Test func aLongListScrollsAndOpensWithTheRowWhereItsDashWas() {
        let outline = layout(Array(repeating: 2, count: 60))
        #expect(outline.cardRect.height == strip.height - 24)
        #expect(outline.maxListOffset > 0)
        let offset = outline.listOffset(placing: 30)
        #expect(offset > 0)
        let row = outline.rowRect(30, listOffset: offset)
        #expect(abs(row.midY - outline.dashY(30)) <= 1)
        #expect(outline.visibleRows(listOffset: offset).contains(30))
        #expect(outline.rowIndex(at: CGPoint(x: row.midX, y: row.midY), listOffset: offset) == 30)
        #expect(outline.clampedListOffset(10_000) == outline.maxListOffset)
        #expect(outline.clampedListOffset(-5) == 0)
    }
}

@Suite("Outline motion")
struct OutlineMotionTests {
    private let outline = layout([1, 2, 2, 3, 1, 2])

    @Test func startsAsTheRailAndEndsAsTheCard() {
        let closed = OutlineMotion.card(outline, progress: 0)
        #expect(closed.opacity == 0)
        #expect(closed.rect == outline.railRect.insetBy(dx: -6, dy: -6))
        let open = OutlineMotion.card(outline, progress: 1)
        #expect(open.opacity == 1)
        #expect(open.rect == outline.cardRect)
        #expect(open.cornerRadius == OutlineLayout.cardCornerRadius)

        for index in 0..<6 {
            let start = OutlineMotion.row(index, in: outline, progress: 0, origin: 2, listOffset: 0)
            #expect(start.dash.rect == outline.dashRect(index))
            #expect(start.dash.opacity == 1)
            #expect(start.text.opacity == 0)
            let end = OutlineMotion.row(index, in: outline, progress: 1, origin: 2, listOffset: 0)
            #expect(end.dash.opacity == 0)
            #expect(end.text.rect == outline.textRect(index, listOffset: 0))
            #expect(end.text.opacity == 1)
            #expect(end.text.blur == 0)
        }
        let dash = OutlineMotion.marker(3, in: outline, progress: 0, origin: 2, listOffset: 0)
        #expect(dash.shape.rect == outline.dashRect(3))
        #expect(dash.accent == 0)
        let dot = OutlineMotion.marker(3, in: outline, progress: 1, origin: 2, listOffset: 0)
        #expect(dot.shape.rect == outline.dotRect(3, listOffset: 0))
        #expect(dot.accent == 1)
    }

    @Test func nothingJumps() {
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        }
        var previous: (card: OutlineMotion.Element, rows: [OutlineMotion.Row], marker: OutlineMotion.Marker)?
        for step in 0...100 {
            let p = CGFloat(step) / 100
            let card = OutlineMotion.card(outline, progress: p)
            let rows = (0..<6).map { OutlineMotion.row($0, in: outline, progress: p, origin: 0, listOffset: 0) }
            let marker = OutlineMotion.marker(5, in: outline, progress: p, origin: 0, listOffset: 0)
            if let previous {
                // The card widens fastest at first: still under 8 pt per step.
                #expect(distance(card.rect, previous.card.rect) < 8)
                #expect(abs(card.opacity - previous.card.opacity) < 0.05)
                for (row, old) in zip(rows, previous.rows) {
                    #expect(distance(row.dash.rect, old.dash.rect) < 4)
                    #expect(distance(row.text.rect, old.text.rect) < 4)
                    #expect(abs(row.text.opacity - old.text.opacity) < 0.05)
                    #expect(abs(row.dash.opacity - old.dash.opacity) < 0.05)
                    #expect(abs(row.text.blur - old.text.blur) < 0.25)
                }
                // The dot leads sideways, fastest as it sets off.
                #expect(distance(marker.shape.rect, previous.marker.shape.rect) < 12)
                #expect(abs(marker.accent - previous.marker.accent) < 0.05)
            }
            previous = (card, rows, marker)
        }
    }

    @Test func rowsSetOffFromTheOrigin() {
        let progress = (0..<6).map { OutlineMotion.rowProgress($0, origin: 2, progress: 0.3) }
        #expect(progress[2] > progress[1])
        #expect(progress[1] > progress[0])
        #expect(progress[3] == progress[1])
        #expect(progress[2] > progress[4])
        for index in 0..<6 {
            #expect(OutlineMotion.rowProgress(index, origin: 2, progress: 0) == 0)
            #expect(OutlineMotion.rowProgress(index, origin: 2, progress: 1) == 1)
        }
    }

    @Test func overshootIsClamped() {
        #expect(OutlineMotion.card(outline, progress: 1.04) == OutlineMotion.card(outline, progress: 1))
        #expect(OutlineMotion.row(1, in: outline, progress: -0.03, origin: 0, listOffset: 0)
            == OutlineMotion.row(1, in: outline, progress: 0, origin: 0, listOffset: 0))
    }

    @Test func reduceMotionOnlyCrossFades() {
        for step in 0...10 {
            let p = CGFloat(step) / 10
            let row = OutlineMotion.row(2, in: outline, progress: p, origin: 0, listOffset: 0, reduceMotion: true)
            #expect(row.dash.rect == outline.dashRect(2))
            #expect(row.text.rect == outline.textRect(2, listOffset: 0))
            #expect(row.text.blur == 0)
            #expect(abs(row.text.opacity + row.dash.opacity - 1) < 0.0001)
            #expect(OutlineMotion.card(outline, progress: p, reduceMotion: true).rect == outline.cardRect)
        }
    }
}

@Suite("Outline scrolling")
struct OutlineScrollingTests {
    @Test func theReadingLineDriftsDownOnlyOverTheLastScreen() {
        func line(remaining: CGFloat, range: CGFloat = 5_000) -> CGFloat {
            OutlineScrolling.readingLineY(visibleTop: 50, visibleHeight: 600, landing: 80, lineHeight: 30,
                                          remainingScroll: remaining, scrollRange: range)
        }
        #expect(line(remaining: 2_000) == 160)
        #expect(line(remaining: 600) == 160)
        #expect(line(remaining: 300) > 160)
        #expect(line(remaining: 0) == 620)
        // A note that doesn't scroll reads from the top.
        #expect(line(remaining: 0, range: 0) == 160)
        // One that scrolls a little drifts over its whole range.
        #expect(line(remaining: 50, range: 100) == CGFloat(160 + 620) / 2)
    }

    @Test func headingsLandWhereTheFirstLineRests() {
        #expect(OutlineScrolling.landing(typewriter: false, topPadding: 90, visibleHeight: 700, lineHeight: 29) == 90)
        #expect(OutlineScrolling.landing(typewriter: true, topPadding: 90, visibleHeight: 700, lineHeight: 30) == 335)
    }

    @Test func glidesEaseOut() {
        #expect(OutlineScrolling.easeOut(0) == 0)
        #expect(OutlineScrolling.easeOut(1) == 1)
        #expect(OutlineScrolling.easeOut(2) == 1)
        #expect(OutlineScrolling.easeOut(0.5) > 0.5)
        #expect(OutlineScrolling.glideDuration(distance: 100, visibleHeight: 700) < OutlineScrolling.glideDuration(distance: 5_000, visibleHeight: 700))
    }
}
