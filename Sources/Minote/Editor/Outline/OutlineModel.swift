import MinoteEditor
import MinoteKit
import SwiftUI

/// What the outline beside the page shows. Written only in Preview (never
/// while typing), and only when a value really changes.
@Observable
final class OutlineModel {
    private(set) var headings: [OutlineHeading] = []
    private(set) var titles: [String] = []
    private(set) var ids: [String] = []
    /// Nil until there is something to lay out.
    var layout: OutlineLayout?
    /// Shown: Preview, at least two headings, room beside the text.
    var isShown = false
    var active: Int?
    var plate: Int?
    var plateStrength: CGFloat = 0
    /// 0 = the rail, 1 = the card (animated).
    var progress: CGFloat = 0
    var origin = 0
    var listOffset: CGFloat = 0
    var reduceMotion = false
    var paper = EditorPaper.standard

    func setHeadings(_ new: [OutlineHeading]) {
        guard new != headings else { return }
        headings = new
        titles = new.map(\.title)
        ids = new.map(\.id)
    }
}

/// The SwiftUI side of the overlay: the model, drawn.
struct OutlineRailHost: View {
    let model: OutlineModel

    var body: some View {
        if let layout = model.layout, layout.count == model.titles.count {
            OutlineRailView(
                layout: layout,
                titles: model.titles,
                ids: model.ids,
                active: model.active,
                plate: model.plate,
                plateStrength: model.plateStrength,
                progress: model.progress,
                origin: model.origin,
                listOffset: model.listOffset,
                reduceMotion: model.reduceMotion,
                palette: .of(model.paper)
            )
            .opacity(model.isShown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
