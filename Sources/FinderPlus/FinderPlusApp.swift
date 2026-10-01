import SwiftUI

@main
struct FinderPlusApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // A window per search — ⌘N opens another, and macOS's automatic window tabbing merges
        // them into tabs — each with its own query, options and results.
        WindowGroup("FinderPlus", id: "search") {
            SearchWindow(appDelegate: appDelegate)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        // The gaps between the glass panels drag the window, as well as the toolbar.
        .windowBackgroundDragBehavior(.enabled)
        .commands { SearchCommands() }

        Settings {
            SettingsView()
                .environment(Preferences.shared)
        }
    }
}

/// One search window. Windows search independently — each holds its own model — while the state
/// behind them is shared through `Preferences.shared`. Whichever window is active registers
/// itself with the delegate, so folders arriving from Finder's service, the Dock or a Shortcuts
/// action land in the window the user is looking at.
private struct SearchWindow: View {
    let appDelegate: AppDelegate
    @State private var model = SearchModel(preferences: .shared)
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(model)
            // What routes the menu bar to this window — see SearchCommands.
            .focusedSceneValue(model)
            .frame(minWidth: 860, minHeight: 500)
            .onAppear {
                appDelegate.model = model
                appDelegate.openSearchWindow = { openWindow(id: "search") }
            }
            .onChange(of: appearsActive) {
                if appearsActive { appDelegate.model = model }
            }
            .onDisappear {
                // A closed window's search would otherwise go on walking the disk unseen.
                model.stop()
                if appDelegate.model === model { appDelegate.model = nil }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How the Shortcuts action reaches this object. `NSApp.delegate` can't: under
    /// `@NSApplicationDelegateAdaptor` it is SwiftUI's own forwarding delegate, not this class.
    /// Set in `init`, which the adaptor runs at launch, before any intent can be performed.
    static private(set) weak var shared: AppDelegate?

    override init() {
        super.init()
        Self.shared = self
    }

    /// The model of the active window. Folders and searches that arrive before a window exists
    /// wait in the `pending` fields below.
    var model: SearchModel? {
        didSet { deliverPending() }
    }

    /// Set by the first window; called to open another when a search arrives after every search
    /// window was closed but Settings kept the app alive.
    var openSearchWindow: (() -> Void)?

    private var pendingFolders: [URL] = []
    private var pendingQuery: String?

    /// Not while a batch runs, or closing the last window would quit without waiting for it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        SearchModel.batchesInFlight == 0
    }

    /// Quitting waits for renames, moves and trashes in flight rather than killing them: a rename
    /// stopped mid-batch leaves files under hidden holding names.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SearchModel.batchesInFlight > 0 else { return .terminateNow }
        SearchModel.onBatchesDrained = {
            SearchModel.onBatchesDrained = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Keeps the Siri phrases for the Shortcuts actions current.
        FinderPlusShortcuts.updateAppShortcutParameters()
        // Starts Sparkle's daily check. Skipped in development builds, which have no feed.
        if Updater.isConfigured { _ = Updater.shared }
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

    /// The "Search in FinderPlus" Shortcuts action: fill the query in, then run the search.
    func searchFromIntent(query: String, folder: URL?) {
        pendingQuery = query
        if let folder { pendingFolders.append(folder) }
        deliver()
    }

    private func search(in urls: [URL]) {
        pendingFolders += urls
        deliver()
    }

    private func deliver() {
        if model == nil { openSearchWindow?() }
        deliverPending()
    }

    private func deliverPending() {
        guard let model, !pendingFolders.isEmpty || pendingQuery != nil else { return }
        if !pendingFolders.isEmpty {
            model.useFolders(pendingFolders)
            pendingFolders = []
        }
        if let query = pendingQuery {
            pendingQuery = nil
            model.query = query
            model.start()
        }
        NSApp.activate()
    }
}

/// The menu bar. `@FocusedValue` hands each command the active window's model, so with several
/// windows open every command lands on the one in front; with none, the items that need a window
/// step aside.
struct SearchCommands: Commands {
    @FocusedValue(SearchModel.self) private var model

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About FinderPlus") { About.showPanel() }
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.isConfigured || !Updater.shared.canCheck)
        }
        CommandGroup(after: .newItem) {
            if let model {
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
                Button("Rename…") { model.requestRename() }
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
                    // The same goes for the Rename sheet's fields, whose files are the selection.
                    .disabled(model.selection.isEmpty || model.isEditingQuery || model.renameRequest != nil)
            }
        }
        CommandGroup(replacing: .sidebar) {
            if let model {
                Button(model.showsSidebar ? "Hide Search Options" : "Show Search Options") { model.showsSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                Button(model.showsPreview ? "Hide Preview" : "Show Preview") { model.showsPreview.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
        CommandMenu("Search") {
            if let model {
                Button("Find…") { model.focusRequest += 1 }
                    .keyboardShortcut("f")
                Button("Choose Location…") { model.choosingFolder = true }
                    .keyboardShortcut("l")
                Button("Start Search") { model.start() }
                    .keyboardShortcut(.return)
                Button("Stop Search") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isSearching && !model.isFindingDuplicates)
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
}
