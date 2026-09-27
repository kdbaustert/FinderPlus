import SwiftUI

/// Shown when FinderPlus opens without Full Disk Access. It closes by itself when the user comes
/// back from System Settings with access turned on.
struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Allow Full Disk Access")
                    .font(.title2.weight(.semibold))
                Text("""
                    FinderPlus searches your whole Mac, but macOS keeps some folders locked — Mail, \
                    Messages, Safari and other apps’ data — until you allow Full Disk Access. \
                    Without it, those folders are skipped and files in them can’t be moved to the Trash.
                    """)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Click Open System Settings.", systemImage: "1.circle")
                Label("Turn on FinderPlus in the Full Disk Access list.", systemImage: "2.circle")
                Label("Come back — this message closes by itself.", systemImage: "3.circle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") { SearchModel.openFullDiskAccessSettings() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
