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
    @Environment(Preferences.self) private var preferences
    /// Re-read on appearing and whenever the app comes back to the front, so it reflects a change
    /// just made in System Settings.
    @State private var hasFullDiskAccess = SearchModel.hasFullDiskAccess()

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Results") {
                Picker("Double-clicking a result", selection: $preferences.settings.doubleClick) {
                    ForEach(AppSettings.DoubleClick.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show full paths in the Location column", isOn: $preferences.settings.showFullPaths)
                Toggle("Ask before moving items to the Trash", isOn: $preferences.settings.confirmTrash)
            }
            Section {
                Toggle("Remember recent searches", isOn: $preferences.settings.rememberRecents)
                LabeledContent("Saved searches") {
                    Button("Clear Recent Searches") { preferences.clearRecents() }
                        .disabled(preferences.recentQueries.isEmpty)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Recent searches appear under the clock in the search field.")
            }
            UpdateSettings()
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
    @Environment(Preferences.self) private var preferences
    @State private var newFolderName = ""

    private static let sizes = [10, 25, 50, 100, 250, 500]
    private static let limits = [0, 1_000, 10_000, 100_000]

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Largest file to read", selection: $preferences.settings.maxContentMegabytes) {
                    ForEach(Self.sizes, id: \.self) { Text("\($0) MB").tag($0) }
                }
            } header: {
                Text("Contents")
            } footer: {
                Text("Content searches skip bigger files. Larger limits find more, but take longer and use more memory.")
            }

            Section {
                Picker("Stop after", selection: $preferences.settings.maxResults) {
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
                ForEach(preferences.settings.skippedFolderNames, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "folder")
                        Spacer()
                        Button {
                            preferences.settings.skippedFolderNames.removeAll { $0 == name }
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
                if preferences.settings.skippedFolderNames.isEmpty {
                    Button("Add Common Developer Folders") {
                        preferences.settings.skippedFolderNames = ["node_modules", ".git", "DerivedData", ".build"]
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
        let known = preferences.settings.skippedFolderNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        if !known { preferences.settings.skippedFolderNames.append(name) }
        newFolderName = ""
    }
}

/// Settings → General → Updates.
private struct UpdateSettings: View {
    var body: some View {
        @Bindable var updater = Updater.shared
        Section {
            if Updater.isConfigured {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                Toggle("Receive beta updates", isOn: $updater.receivesBetas)
                LabeledContent("Last checked") {
                    Text(updater.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                LabeledContent("Updates") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
            } else {
                Text("This development build doesn’t update itself. Copies installed from a GitHub release do.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("""
                New versions come from FinderPlus’s releases on GitHub. Each is signed, and checked before \
                it installs. Betas arrive before stable releases and are less proven; turning them off keeps \
                the beta you have until a newer stable release comes out.
                """)
        }
    }
}
