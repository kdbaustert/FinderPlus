import SwiftUI

/// The Settings window (⌘,). Search options stay in the main window's panel; these are the
/// preferences that shape how the app behaves rather than what one search looks for.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchSettings()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        // Tall enough for the Search tab's folder list without scrolling.
        .frame(width: 520, height: 600)
    }
}

private struct GeneralSettings: View {
    @Environment(SearchModel.self) private var model
    /// Re-read on appearing and whenever the app comes back to the front, so it reflects a change
    /// just made in System Settings.
    @State private var hasFullDiskAccess = SearchModel.hasFullDiskAccess()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Results") {
                Picker("Double-clicking a result", selection: $model.settings.doubleClick) {
                    ForEach(AppSettings.DoubleClick.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show full paths in the Location column", isOn: $model.settings.showFullPaths)
                Toggle("Ask before moving items to the Trash", isOn: $model.settings.confirmTrash)
            }
            Section {
                Toggle("Remember recent searches", isOn: $model.settings.rememberRecents)
                LabeledContent("Saved searches") {
                    Button("Clear Recent Searches") { model.clearRecents() }
                        .disabled(model.recentQueries.isEmpty)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Recent searches appear under the clock in the search field.")
            }
            Section {
                LabeledContent("Full Disk Access") {
                    if hasFullDiskAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 10) {
                            Label("Not granted", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Open System Settings") { SearchModel.openFullDiskAccessSettings() }
                        }
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Without Full Disk Access, macOS keeps some folders locked: FinderPlus skips them and can’t move files in them to the Trash.")
            }
        }
        .formStyle(.grouped)
        .onAppear { hasFullDiskAccess = SearchModel.hasFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = SearchModel.hasFullDiskAccess()
        }
    }
}

private struct SearchSettings: View {
    @Environment(SearchModel.self) private var model
    @State private var newFolderName = ""

    private static let sizes = [10, 25, 50, 100, 250, 500]
    private static let limits = [0, 1_000, 10_000, 100_000]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Largest file to read", selection: $model.settings.maxContentMegabytes) {
                    ForEach(Self.sizes, id: \.self) { Text("\($0) MB").tag($0) }
                }
            } header: {
                Text("Contents")
            } footer: {
                Text("Content searches skip bigger files. Larger limits find more, but take longer and use more memory.")
            }

            Section {
                Picker("Stop after", selection: $model.settings.maxResults) {
                    ForEach(Self.limits, id: \.self) { limit in
                        Text(limit == 0 ? "No limit" : "\(limit.formatted()) matches").tag(limit)
                    }
                }
            } header: {
                Text("Results")
            } footer: {
                Text("A limit keeps very broad searches fast and light.")
            }

            Section {
                ForEach(model.settings.skippedFolderNames, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "folder")
                        Spacer()
                        Button {
                            model.settings.skippedFolderNames.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop skipping “\(name)”")
                    }
                }
                HStack {
                    TextField("Folder name", text: $newFolderName, prompt: Text("e.g. node_modules"))
                        .onSubmit(addFolderName)
                    Button("Add", action: addFolderName)
                        .disabled(trimmedName.isEmpty)
                }
                if model.settings.skippedFolderNames.isEmpty {
                    Button("Add Common Developer Folders") {
                        model.settings.skippedFolderNames = ["node_modules", ".git", "DerivedData", ".build"]
                    }
                }
            } header: {
                Text("Always skip folders named")
            } footer: {
                Text("Folders with these names are never searched, wherever they are. Names ignore case.")
            }
        }
        .formStyle(.grouped)
    }

    private var trimmedName: String {
        newFolderName.trimmingCharacters(in: .whitespaces)
    }

    private func addFolderName() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        let known = model.settings.skippedFolderNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        if !known { model.settings.skippedFolderNames.append(name) }
        newFolderName = ""
    }
}
