import MinoteKit
import SwiftUI
import MinoteEditor

/// The word counter in the bottom corner. Click to switch between words,
/// characters and reading time.
struct WordCounter: View {
    let windowState: WindowState
    @AppStorage(PreferenceKey.counterMetric) private var metric = Metric.words

    enum Metric: String {
        case words, characters, readingTime

        var next: Metric {
            switch self {
            case .words: .characters
            case .characters: .readingTime
            case .readingTime: .words
            }
        }
    }

    var body: some View {
        Button {
            metric = metric.next
        } label: {
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to switch between words, characters and reading time")
        .accessibilityLabel(label)
    }

    private var label: String {
        let statistics = windowState.statistics
        let suffix = windowState.statisticsAreForSelection ? " selected" : ""
        switch metric {
        case .words:
            return "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")\(suffix)"
        case .characters:
            return "\(statistics.characters.formatted()) \(statistics.characters == 1 ? "character" : "characters")\(suffix)"
        case .readingTime:
            let minutes = statistics.readingMinutes
            return minutes == 0 ? "No reading time" : "\(minutes) min read\(suffix)"
        }
    }
}
