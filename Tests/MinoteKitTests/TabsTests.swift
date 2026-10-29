import Foundation
import Testing
@testable import MinoteKit

@Suite("Tabs")
struct TabsTests {
    // MARK: Where an opened note goes

    @Test func anUntouchedLibraryTabIsReplaced() {
        #expect(OpenPlacement.of(isOpen: false, front: .libraryNote(edited: false)) == .replaceFront)
    }

    @Test func anEditedLibraryTabIsKept() {
        #expect(OpenPlacement.of(isOpen: false, front: .libraryNote(edited: true)) == .newTab)
    }

    @Test func aFileFromFinderIsNeverReplaced() {
        #expect(OpenPlacement.of(isOpen: false, front: .outsideFile) == .newTab)
    }

    @Test(arguments: [OpenPlacement.FrontTab.libraryNote(edited: false), .libraryNote(edited: true), .outsideFile, nil])
    func anOpenNoteComesForward(_ front: OpenPlacement.FrontTab?) {
        #expect(OpenPlacement.of(isOpen: true, front: front) == .focusExisting)
        #expect(OpenPlacement.of(isOpen: true, front: front, forceNewTab: true) == .focusExisting)
    }

    @Test func askingForANewTabNeverReplaces() {
        #expect(OpenPlacement.of(isOpen: false, front: .libraryNote(edited: false), forceNewTab: true) == .newTab)
    }

    @Test func withoutAWindowANewOneOpens() {
        #expect(OpenPlacement.of(isOpen: false, front: nil) == .newWindow)
        #expect(OpenPlacement.of(isOpen: false, front: nil, forceNewTab: true) == .newWindow)
    }

    // MARK: Tabs kept across launches

    @Test func savedTabsRoundTrip() {
        let defaults = freshDefaults()
        let saved = SavedTabs(windows: [.init(notes: ["A.md", "B.md"], front: 1), .init(notes: ["C.md"], front: 0)])
        saved.save(to: defaults)
        #expect(SavedTabs.load(from: defaults) == saved)
        #expect(SavedTabs.load(from: freshDefaults()) == nil)
    }

    @Test func restoringDropsNotesThatAreGone() {
        let saved = SavedTabs(windows: [.init(notes: ["A.md", "Gone.md", "B.md"], front: 2)])
        let restored = saved.restored(existing: ["A.md", "B.md"])
        #expect(restored.windows == [.init(notes: ["A.md", "B.md"], front: 1)])
    }

    @Test func aGoneFrontTabHandsOverToTheNextOne() {
        let saved = SavedTabs(windows: [.init(notes: ["A.md", "Gone.md", "B.md", "C.md"], front: 1)])
        #expect(saved.restored(existing: ["A.md", "B.md", "C.md"]).windows == [.init(notes: ["A.md", "B.md", "C.md"], front: 1)])
        // The last tab was in front and is gone: the one before it.
        let last = SavedTabs(windows: [.init(notes: ["A.md", "Gone.md"], front: 1)])
        #expect(last.restored(existing: ["A.md"]).windows == [.init(notes: ["A.md"], front: 0)])
    }

    @Test func untouchedTabsStayUntouched() {
        let saved = SavedTabs(windows: [.init(notes: ["A.md", "B.md", "C.md"], front: 0, untouched: ["B.md", "Gone.md"])])
        let restored = saved.restored(existing: ["A.md", "B.md"])
        #expect(restored.windows == [.init(notes: ["A.md", "B.md"], front: 0, untouched: ["B.md"])])
        #expect(restored.windows[0].isUntouched("B.md"))
        #expect(!restored.windows[0].isUntouched("A.md"))
        // Saved before untouched tabs were kept: every tab is kept.
        let old = try! JSONDecoder().decode(SavedTabs.self, from: Data(#"{"windows":[{"notes":["A.md"],"front":0}]}"#.utf8))
        #expect(!old.windows[0].isUntouched("A.md"))
    }

    @Test func aWindowWithoutNotesLeftIsDropped() {
        let saved = SavedTabs(windows: [.init(notes: ["Gone.md"], front: 0), .init(notes: ["A.md"], front: 5)])
        #expect(saved.restored(existing: ["A.md"]).windows == [.init(notes: ["A.md"], front: 0)])
    }

    // MARK: The tab bar's layout

    @Test func tabsAreAsWideAsFitUpToTheMaximum() {
        let roomy = TabStripLayout(count: 2, available: 1000)
        #expect(roomy.tabWidth == TabStripLayout.maxTabWidth)
        #expect(roomy.visibleWidth == 2 * TabStripLayout.maxTabWidth)
        #expect(!roomy.scrolls)

        let tight = TabStripLayout(count: 5, available: 801)
        #expect(tight.tabWidth == 160)
        #expect(tight.visibleWidth == 800)
        #expect(!tight.scrolls)
    }

    @Test func pastTheMinimumTheBarScrolls() {
        let crowded = TabStripLayout(count: 10, available: 600)
        #expect(crowded.tabWidth == TabStripLayout.minTabWidth)
        #expect(crowded.contentWidth == 10 * TabStripLayout.minTabWidth)
        #expect(crowded.visibleWidth == 600)
        #expect(crowded.scrolls)
    }

    @Test func noRoomAtAllShowsNothing() {
        let layout = TabStripLayout(count: 3, available: -20)
        #expect(layout.visibleWidth == 0)
        #expect(TabStripLayout(count: 0, available: 500).contentWidth == 0)
    }

    @Test func aDraggedTabTakesItsNeighborsPlacePastItsMiddle() {
        let layout = TabStripLayout(count: 4, available: 400, minTabWidth: 80)   // 100 wide
        #expect(layout.dropIndex(from: 1, translation: 49) == 1)
        #expect(layout.dropIndex(from: 1, translation: 51) == 2)
        #expect(layout.dropIndex(from: 1, translation: -60) == 0)
        #expect(layout.dropIndex(from: 1, translation: 900) == 3)
        #expect(layout.dropIndex(from: 1, translation: -900) == 0)
    }

    @Test func neighborsStepAsideForTheDraggedTab() {
        let layout = TabStripLayout(count: 4, available: 400, minTabWidth: 80)
        // Tab 0 dragged over tab 2: tabs 1 and 2 move left.
        #expect((0..<4).map { layout.shift(of: $0, dragging: 0, over: 2) } == [0, -100, -100, 0])
        // Tab 3 dragged over tab 1: tabs 1 and 2 move right.
        #expect((0..<4).map { layout.shift(of: $0, dragging: 3, over: 1) } == [0, 100, 100, 0])
        #expect((0..<4).map { layout.shift(of: $0, dragging: 2, over: 2) } == [0, 0, 0, 0])
    }

    @Test func aDraggedTabStaysInTheBar() {
        let layout = TabStripLayout(count: 3, available: 300, minTabWidth: 80)
        #expect(layout.clampedTranslation(-500, from: 1) == -100)
        #expect(layout.clampedTranslation(500, from: 1) == 100)
        #expect(layout.clampedTranslation(30, from: 1) == 30)
    }
}
