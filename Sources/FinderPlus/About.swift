import AppKit
import SwiftUI

/// Who made FinderPlus and where it lives. Shared by the About window and the About tab in
/// Settings so the two never disagree.
enum About {
    static let author = "Kenny Baustert"
    static let profile = URL(string: "https://github.com/kdbaustert")!
    static let repository = URL(string: "https://github.com/kdbaustert/FinderPlus")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    /// The standard About window: the author's name links to their profile, then the repository.
    @MainActor
    static func showPanel() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        func link(_ title: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: title, attributes: body.merging([.link: url]) { $1 })
        }
        let credits = NSMutableAttributedString(string: "Created by ", attributes: body)
        credits.append(link(author, profile))
        credits.append(NSAttributedString(string: "\n\n", attributes: body))
        credits.append(link("github.com/kdbaustert/FinderPlus", repository))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// The About tab in Settings.
struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("FinderPlus")
                    .font(.title.weight(.semibold))
                Text(About.version)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Fast, index-free file search for your Mac.")
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Created by")
                Link(About.author, destination: About.profile)
                    .help(About.profile.absoluteString)
            }
            .font(.headline)

            Link(destination: About.repository) {
                Label("FinderPlus Repository", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.glass)

            Text("Licensed under the GNU General Public License v3.0.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
