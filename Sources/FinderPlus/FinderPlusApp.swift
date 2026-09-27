import SwiftUI

@main
struct FinderPlusApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = SearchModel()

    var body: some Scene {
        Window("FinderPlus", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 860, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        // The gaps between the glass panels drag the window, as well as the toolbar.
        .windowBackgroundDragBehavior(.enabled)
        .commands { SearchCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window exists. Folders that arrive before then wait in `pendingFolders`.
    var model: SearchModel? {
        didSet { searchPendingFolders() }
    }

    private var pendingFolders: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Folders dropped on the Dock icon, or opened with FinderPlus.
    func application(_ application: NSApplication, open urls: [URL]) {
        search(in: urls)
    }

    /// The "Search with FinderPlus" service, offered for folders in Finder's right-click menu.
    /// AppKit finds it by the selector named in Info.plist's NSServices.
    @objc func searchWithFinderPlus(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        search(in: urls ?? [])
    }

    private func search(in urls: [URL]) {
        pendingFolders += urls
        searchPendingFolders()
    }

    private func searchPendingFolders() {
        guard let model, !pendingFolders.isEmpty else { return }
        model.useFolders(pendingFolders)
        pendingFolders = []
        NSApp.activate()
    }
}

struct SearchCommands: Commands {
    let model: SearchModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About FinderPlus") { About.showPanel() }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { model.open() }
                .keyboardShortcut("o")
                .disabled(model.selection.isEmpty)
            Button("Show in Finder") { model.reveal() }
                .keyboardShortcut("r")
                .disabled(model.selection.isEmpty)
            Button("Quick Look") { model.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model.selection.isEmpty)
            Button("Copy Path") { model.copyPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selection.isEmpty)
            Button("Copy Rows") { model.copyRows() }
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Copy To…") { Task { await model.transfer(nil, .copy) } }
                .disabled(model.selection.isEmpty)
            Button("Move To…") { Task { await model.transfer(nil, .move) } }
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Export Results…") { model.exportResults() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty)
            Divider()
            Button("Move to Trash") { Task { await model.trash() } }
                .keyboardShortcut(.delete)
                // ⌘⌫ in the search field deletes to the start of the line; menu shortcuts are
                // matched first, so without this it would trash the selected results instead.
                .disabled(model.selection.isEmpty || model.isEditingQuery)
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.showsSidebar ? "Hide Search Options" : "Show Search Options") { model.showsSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button(model.showsPreview ? "Hide Preview" : "Show Preview") { model.showsPreview.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
        CommandMenu("Search") {
            Button("Find…") { model.focusRequest += 1 }
                .keyboardShortcut("f")
            Button("Choose Location…") { model.choosingFolder = true }
                .keyboardShortcut("l")
            Button("Start Search") { model.start() }
                .keyboardShortcut(.return)
            Button("Stop Search") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!model.isSearching)
            Divider()
            Button("Find Duplicates in Results") { model.findDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty || model.isSearching || model.isFindingDuplicates)
            Button("Show All Results") { model.leaveDuplicates() }
                .disabled(!model.showsDuplicates)
            Divider()
            Picker("Search For", selection: Bindable(model).options.kind) {
                ForEach(SearchKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Operator", selection: Bindable(model).options.mode) {
                ForEach(MatchMode.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}
