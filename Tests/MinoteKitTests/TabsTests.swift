import Foundation
import Testing
@testable import MinoteKit

@Suite("Tabs")
struct TabsTests {
    // MARK: Where an opened note goes

    @Test func anUntouchedLibraryTabIsReplaced() {
        #expect(TabPlacement.of(isOpen: false, front: .libraryNote(edited: false)) == .replaceFront)
    }

    @Test func anEditedLibraryTabIsKept() {
        #expect(TabPlacement.of(isOpen: false, front: .libraryNote(edited: true)) == .newTab)
    }

    @Test func aFileFromFinderIsNeverReplaced() {
        #expect(TabPlacement.of(isOpen: false, front: .outsideFile) == .newTab)
    }

    @Test(arguments: [TabPlacement.FrontTab.libraryNote(edited: false), .libraryNote(edited: true), .outsideFile, nil])
    func anOpenNoteComesForward(_ front: TabPlacement.FrontTab?) {
        #expect(TabPlacement.of(isOpen: true, front: front) == .focusExisting)
        #expect(TabPlacement.of(isOpen: true, front: front, forceNewTab: true) == .focusExisting)
    }

    @Test func askingForANewTabNeverReplaces() {
        #expect(TabPlacement.of(isOpen: false, front: .libraryNote(edited: false), forceNewTab: true) == .newTab)
    }

    @Test func withoutAWindowANewOneOpens() {
        #expect(TabPlacement.of(isOpen: false, front: nil) == .newWindow)
        #expect(TabPlacement.of(isOpen: false, front: nil, forceNewTab: true) == .newWindow)
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

    @Test func aWindowWithoutNotesLeftIsDropped() {
        let saved = SavedTabs(windows: [.init(notes: ["Gone.md"], front: 0), .init(notes: ["A.md"], front: 5)])
        #expect(saved.restored(existing: ["A.md"]).windows == [.init(notes: ["A.md"], front: 0)])
    }
}
