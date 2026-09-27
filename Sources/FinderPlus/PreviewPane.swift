import Quartz
import SwiftUI

/// The panel beside the results: details of the selected file, then either its text with every
/// match marked (when the search read inside files) or the standard Quick Look preview.
struct PreviewPane: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        Group {
            if let hit = model.hits(nil).first {
                VStack(alignment: .leading, spacing: 0) {
                    PreviewHeader(hit: hit)
                        .padding(14)
                    Rectangle().fill(Color.border).frame(height: 1)
                    if let context = model.previewContext, hit.snippet != nil, !hit.isArchiveEntry {
                        MatchesPreview(hit: hit, context: context)
                            .id(hit.id)
                    } else {
                        QuickLookView(url: hit.url)
                            .id(hit.id)
                    }
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "eye",
                                       description: Text("Select a result to preview it."))
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
    }
}

private struct PreviewHeader: View {
    let hit: FileHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: ResultsView.icon(for: hit))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.name)
                    .font(.headline)
                    .lineLimit(2)
                Text([hit.kind, hit.size < 0 ? nil : hit.sizeText].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text("Modified \(hit.modified.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                Text(hit.fullPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}

/// The file's text with every match in bold accent colour. Loaded off the main thread and capped,
/// so a large document cannot stall the window.
private struct MatchesPreview: View {
    let hit: FileHit
    let context: SearchModel.PreviewContext
    @State private var loaded: (text: String, ranges: [NSRange])?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let loaded {
                HighlightedText(text: loaded.text, ranges: loaded.ranges)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Text to Show", systemImage: "doc.text")
            }
        }
        .task {
            let (url, size, context) = (hit.url, hit.size, context)
            loaded = await Task.detached {
                let full = SearchEngine.contentText(of: url, size: size, recognizeText: context.recognizeText)
                    ?? DocumentText.metadataText(of: url)
                guard let full else { return nil }
                let text = (full as NSString).length > 1_000_000 ? (full as NSString).substring(to: 1_000_000) : full
                return (text, context.matcher.ranges(in: text))
            }.value
            isLoading = false
        }
    }
}

private struct HighlightedText: NSViewRepresentable {
    let text: String
    let ranges: [NSRange]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let match: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.controlAccentColor,
        ]
        let string = NSMutableAttributedString(string: text, attributes: body)
        let length = string.length
        let visible = ranges.filter { NSMaxRange($0) <= length }
        for range in visible { string.addAttributes(match, range: range) }
        textView.textStorage?.setAttributedString(string)
        if let first = visible.first {
            DispatchQueue.main.async { textView.scrollRangeToVisible(first) }
        }
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
