import SwiftUI

@main
struct FinderPlusApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = SearchModel()

    var body: some Scene {
        Window("FinderPlus", id: "main") {
            ContentView()
                .environment(model)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
            Picker("Search For", selection: Bindable(model).options.kind) {
                ForEach(SearchKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Operator", selection: Bindable(model).options.mode) {
                ForEach(MatchMode.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}
