import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A glass toolbar over the search options and results, on a translucent window with one even tint.
struct ContentView: View {
    @Environment(SearchModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Under the toolbar too, so the toolbar matches everything below it.
            WindowTint().ignoresSafeArea()
            HStack(spacing: 0) {
                if model.showsSidebar {
                    OptionsPanel()
                        .frame(width: 244)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color.border)
                                .frame(width: 1)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // The status sits in its own row under the results. Without a background it cannot
                // float over them, and the table ignores a safe-area inset, drawing rows beneath it.
                //
                // The search bar sits above the results rather than in a bar attached to them: a bar
                // lets the table's scroll area reach up under it and under the toolbar, and macOS
                // paints the table's column-header backing across all of that, as a grey block over
                // the glass.
                VStack(spacing: 0) {
                    SearchHeader()
                    ResultsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.phase != .idle, !isFailed {
                        StatusPill()
                            .transition(.opacity)
                    }
                }
                .animation(.spring(duration: 0.35), value: model.phase)
                // The results side darker than the sidebar, edge to edge from its border.
                .background(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08))
            }
            // A divider under the toolbar, full width. The sidebar and search area start right at it
            // (their extra breathing room is inside them) so the sidebar's border meets this line.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.border)
                    .frame(height: 1)
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .sheet(isPresented: Bindable(model).showsFullDiskAccessPrompt) {
            FullDiskAccessSheet()
        }
        .sheet(item: Bindable(model).renameRequest) { request in
            RenameSheet(hits: request.hits)
        }
        // Here rather than on the Location menu, which is gone while the sidebar is hidden and
        // would leave ⌘L doing nothing until the sidebar came back.
        .fileImporter(isPresented: Bindable(model).choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addFolders([url]) }
        }
        .task { model.checkFullDiskAccessAtLaunch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
        .navigationTitle("FinderPlus")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.showsSidebar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showsSidebar.toggle() } label: {
                Label("Search Options", systemImage: "sidebar.left")
            }
            .help(model.showsSidebar ? "Hide Search Options (⌃⌘S)" : "Show Search Options (⌃⌘S)")
        }
        .sharedBackgroundVisibility(.hidden)

        // Everything here acts on the selected results, and sits idle until there are some.
        ToolbarItemGroup(placement: .primaryAction) {
            action("Quick Look", symbol: "eye", help: "Quick Look (Space)") { model.toggleQuickLook() }
            action("Open", symbol: "arrow.up.forward.app", help: "Open (⌘O)") { model.open() }
            action("Show in Finder", symbol: "folder", help: "Show in Finder (⌘R)") { model.reveal() }
            action("Copy Path", symbol: "doc.on.doc", help: "Copy Path (⌥⌘C)") { model.copyPaths() }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            ShareLink(items: model.selectedURLs) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selection.isEmpty)
            .help("Share")
            action("Move to Trash", symbol: "trash", help: "Move to Trash (⌘⌫)") {
                Task { await model.trash() }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { model.showsPreview.toggle() } label: {
                Label("Preview", systemImage: "sidebar.right")
            }
            .help(model.showsPreview ? "Hide Preview (⌥⌘P)" : "Show Preview (⌥⌘P)")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func action(_ title: String, symbol: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
        }
        .disabled(model.selection.isEmpty)
        .help(help)
    }

    private var subtitle: String {
        let place = model.location.title
        return switch model.phase {
        case .idle, .failed: place
        case .searching: "Searching \(place)…"
        case .finished, .stopped: "\(model.results.count.formatted()) matches in \(place)"
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}

/// One even tint over the translucent window, the same everywhere — sidebar, results and toolbar —
/// so no area reads as highlighted against another. It is what makes the glass a little darker.
struct WindowTint: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.black
            .opacity(colorScheme == .dark ? 0.22 : 0.07)
            .allowsHitTesting(false)
    }
}

// MARK: - Search header

struct SearchHeader: View {
    @Environment(SearchModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: model.options.searchContents ? "doc.text.magnifyingglass" : "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                        TextField(model.options.prompt, text: $model.query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($fieldFocused)
                            // Return is taken here rather than through onSubmit: letting the field
                            // handle it selects the whole query, so the next keystroke replaced
                            // everything typed so far.
                            .onKeyPress(.return) {
                                model.start()
                                return .handled
                            }
                            .onKeyPress(.downArrow) {
                                guard !model.results.isEmpty else { return .ignored }
                                model.resultsFocusRequest += 1
                                return .handled
                            }
                        if !model.query.isEmpty {
                            Button {
                                model.query = ""
                                fieldFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear")
                        }
                        RecentsMenu()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    // A dark tint on the glass, so the field sits a shade deeper than the window.
                    .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .capsule)

                    if model.isSearching || model.isFindingDuplicates {
                        Button(role: .cancel) { model.stop() } label: {
                            Label("Stop", systemImage: "stop.fill").padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .controlSize(.extraLarge)
                    } else {
                        Button { model.start() } label: {
                            Label("Find", systemImage: "arrow.forward").padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || !model.options.searchesAnyField)
                    }
            }
            if !model.showsSidebar {
                // With the panel hidden, what the search will do is otherwise invisible.
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .animation(.smooth(duration: 0.3), value: model.isSearching || model.isFindingDuplicates)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.showsSidebar)
        .onChange(of: model.focusRequest) { fieldFocused = true }
        .onChange(of: fieldFocused) { model.isEditingQuery = fieldFocused }
        // Initial focus only. Focusing on every appearance re-selected the whole query whenever the
        // header was rebuilt, so the next keystroke replaced everything already typed.
        .defaultFocus($fieldFocused, true)
    }

    private var summary: String {
        [model.location.title, model.options.kind.title, model.options.mode.title].joined(separator: " · ")
    }
}

struct RecentsMenu: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        Menu {
            if model.recentQueries.isEmpty {
                Text("No Recent Searches")
            } else {
                Section("Recent Searches") {
                    ForEach(model.recentQueries, id: \.self) { query in
                        // Fills the field only; the search waits for Find like any other.
                        Button(query) { model.query = query }
                    }
                }
                Divider()
                Button("Clear Recent Searches") { model.clearRecents() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Recent searches")
    }
}

// MARK: - Options panel

/// EasyFind's options column — Location, Search for, Operator, Comparison, Include — rebuilt as
/// grouped cards on a glass panel. Every change re-runs a search already on screen.
struct OptionsPanel: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OptionSection("Location") {
                    LocationMenu()
                }

                OptionSection("Search for") {
                    Picker("Search for", selection: $model.options.kind) {
                        ForEach(SearchKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Divider()
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    Toggle("Name", isOn: $model.options.searchNames)
                    Toggle("Contents", isOn: $model.options.searchContents)
                        .help("Read inside text, PDF, Word, Excel, PowerPoint, OpenDocument, EPUB and web files.")
                    Toggle("Text in Images", isOn: $model.options.recognizeText)
                        .padding(.leading, 20)
                        .disabled(!model.options.searchContents)
                        .help("Read the text in photos, screenshots and scanned PDFs. Much slower.")
                    Toggle("Tags", isOn: $model.options.searchTags)
                    Toggle("Comments", isOn: $model.options.searchComments)
                        .help("The comment from Finder’s Get Info window")
                    Toggle("Metadata", isOn: $model.options.searchMetadata)
                        .help("Camera, lens and date taken; artist, album and title; owner and permissions.")
                }

                OptionSection("Operator") {
                    Picker("Operator", selection: $model.options.mode) {
                        ForEach(MatchMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(model.options.mode.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }

                OptionSection("Comparison") {
                    Toggle("Ignore Case", isOn: $model.options.ignoreCase)
                    Toggle("Ignore Accents", isOn: $model.options.ignoreDiacritics)
                        .help("Treat é, ü and e, u as the same letter")
                    Toggle("Fuzzy", isOn: $model.options.fuzzy)
                        .disabled(!model.options.mode.supportsFuzzy)
                        .help("Tolerate a typo or two in longer words. Not available for patterns.")
                    Toggle("Whole Words", isOn: $model.options.wholeWords)
                        .disabled(model.options.usesFuzzy)
                }

                OptionSection("Filters") {
                    Picker("Modified", selection: $model.options.modified) {
                        ForEach(DateFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Size", selection: $model.options.size) {
                        ForEach(SizeFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Leave out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(KindGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(
                            get: { model.options.excludedKinds.contains(group) },
                            set: { isOn in
                                if isOn {
                                    model.options.excludedKinds.insert(group)
                                } else {
                                    model.options.excludedKinds.remove(group)
                                }
                            }))
                    }
                }

                OptionSection("Include") {
                    Toggle("Package Contents", isOn: $model.options.includePackageContents)
                        .help("Look inside apps, bundles and other packages")
                    Toggle("Invisible Files & Folders", isOn: $model.options.includeHidden)
                    Toggle("Inside Zip Archives", isOn: $model.options.includeArchiveContents)
                        .help("List the files inside .zip archives by name, without unpacking them")
                    Toggle("Applications", isOn: $model.options.includeApplications)
                        .help("Apps and the Applications folders. Turn off to leave them out of searches.")
                    Toggle("System Folders", isOn: Binding(
                        get: { !model.options.excludeSystemFolders },
                        set: { model.options.excludeSystemFolders = !$0 }))
                        .help("/System, /Library, /usr and similar, when searching from the top of a volume")
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .animation(.snappy, value: model.options)
        }
        .scrollIndicators(.never)
        // Otherwise the toolbar tints a band above this scroll view, giving the title and the
        // traffic lights a different background from the rest of the toolbar.
        .scrollEdgeEffectHidden(true, for: .top)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFolders(urls)
            return true
        }
    }
}

/// A titled group of options.
struct OptionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        }
    }
}

/// The Location dropdown, laid out like EasyFind's: pick a folder, the front Finder window, a set
/// of volumes, one drive, a familiar place, or a folder you added before.
struct LocationMenu: View {
    @Environment(SearchModel.self) private var model
    /// Bumped when a drive mounts or unmounts, so the drive list is re-read.
    @State private var driveRevision = 0

    var body: some View {
        let _ = driveRevision
        let drives = SearchLocation.drives()
        Menu {
            Button("Select…") { model.choosingFolder = true }
                .keyboardShortcut("l")
            Divider()
            choices([.activeFinderWindow])
            Divider()
            choices(SearchLocation.scopes)
            Divider()
            choices(drives)
            Divider()
            choices(SearchLocation.places)
            if !model.customLocations.isEmpty {
                Divider()
                choices(model.customLocations)
                Menu("Remove Folder") {
                    ForEach(model.customLocations) { location in
                        Button(location.title) { model.removeFolder(location) }
                    }
                }
            }
        } label: {
            Label(model.location.title, systemImage: model.location.symbol)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        // Glass buttons hug their label unless told otherwise; this one is a full-width pop-up.
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
        .controlSize(.large)
        .menuIndicator(.hidden)
        // Overlaid rather than in the label: a menu button keeps only a label's icon and title.
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        }
        .help(model.location.help)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            driveRevision += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            driveRevision += 1
        }
    }

    /// One group of menu items, the current location checkmarked. Toggles rather than inline
    /// pickers: several pickers sharing one selection checkmark every row, and hiding their
    /// headers hides every item's title with them. Folders and drives show their Finder icons;
    /// the scopes, which are not a single place on disk, show symbols.
    private func choices(_ locations: [SearchLocation]) -> some View {
        ForEach(locations) { location in
            Toggle(isOn: Binding(
                // The resolved location, not the raw ID: a saved "" and "@all" are both All Volumes.
                get: { model.location == location },
                set: { if $0 { model.locationID = location.id } }
            )) {
                Label {
                    Text(location.title)
                } icon: {
                    if let path = location.path {
                        Image(nsImage: Self.icon(forPath: path))
                    } else {
                        Image(systemName: location.symbol)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private static func icon(forPath path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Results

struct ResultsView: View {
    @Environment(SearchModel.self) private var model
    @FocusState private var tableFocused: Bool

    var body: some View {
        @Bindable var model = model
        // The table stays mounted and the empty states sit over it. Swapping one for the other
        // rebuilt the scroll view the search bar is attached to, which re-created the search field
        // mid-typing and lost the text in it.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.showsDuplicates { DuplicatesBanner() }
                table
                    .opacity(model.results.isEmpty ? 0 : 1)
                    .allowsHitTesting(!model.results.isEmpty)
                    .overlay {
                        if model.results.isEmpty { placeholder }
                    }
            }
            if model.showsPreview {
                Rectangle().fill(Color.border).frame(width: 1)
                PreviewPane()
            }
        }
        .quickLookPreview($model.previewURL, in: model.selectedURLs)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: FileHit.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            // Only in the duplicates view: which set of identical files each row belongs to.
            if model.showsDuplicates {
                TableColumn("Set") { hit in
                    Text(model.duplicateSets[hit.id].map(String.init) ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 30, ideal: 36, max: 50)
            }

            TableColumn("Name", value: \.name) { hit in
                HStack(spacing: 7) {
                    Image(nsImage: Self.icon(for: hit))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(hit.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)

            // Second, so the file's folder is on screen at any window width rather than being the
            // last column, pushed past the right edge.
            TableColumn("Location", value: \.parentPath) { hit in
                Label {
                    Text(model.settings.showFullPaths ? hit.parentPath : hit.displayParent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .foregroundStyle(.secondary)
                .help(hit.parentPath)
            }
            .width(min: 160, ideal: 320)

            // Only for content searches; otherwise it is an empty column with a squeezed title.
            if model.searchedContents {
                TableColumn("Match", value: \.snippetText) { hit in
                    Text(Self.highlighted(hit.snippet))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(hit.snippetText)
                }
                .width(min: 120, ideal: 280)
            }

            TableColumn("Kind", value: \.kind) { hit in
                Text(hit.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 120)

            TableColumn("Size", value: \.size) { hit in
                Text(hit.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Date Modified", value: \.modified) { hit in
                Text(hit.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Date Created", value: \.created) { hit in
                Text(hit.created, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)

        } rows: {
            ForEach(model.results) { hit in
                TableRow(hit).draggable(hit.url)
            }
        }
        // Transparent, so rows sit directly on the window's glass.
        .scrollContentBackground(.hidden)
        // No toolbar band above the table either, so the whole toolbar is one even surface.
        .scrollEdgeEffectHidden(true, for: .top)
        .alternatingRowBackgrounds(.disabled)
        .focused($tableFocused)
        .onChange(of: model.resultsFocusRequest) {
            tableFocused = true
            if model.selection.isEmpty, let first = model.results.first { model.selection = [first.id] }
        }
        .contextMenu(forSelectionType: FileHit.ID.self) { ids in
            ResultMenu(ids: ids)
        } primaryAction: { ids in
            model.performDefaultAction(ids)
        }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        // Finder trashes on ⌘⌫ only; a bare ⌫ is too easy to hit, and with "Ask before moving to
        // Trash" off it would trash the selection outright. ⌘⌫ normally reaches the menu item first.
        .onDeleteCommand {
            guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return }
            Task { await model.trash() }
        }
        .onChange(of: model.sortOrder) { model.resort() }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Find Anything", systemImage: "doc.text.magnifyingglass")
                    .symbolRenderingMode(.hierarchical)
            } description: {
                Text("Search names, contents, tags and comments across your Mac — including hidden and un-indexed files. No Spotlight index required.")
            }
        case .searching:
            ContentUnavailableView {
                Label("Searching…", systemImage: "magnifyingglass")
                    .symbolEffect(.pulse)
            } description: {
                Text("Matches appear here as they are found.")
            }
        case .finished, .stopped:
            ContentUnavailableView.search(text: model.query)
        case .failed(let message):
            ContentUnavailableView("Can’t Search", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    /// A file inside an archive has no file of its own to ask for an icon, so it gets its type's.
    static func icon(for hit: FileHit) -> NSImage {
        guard hit.isArchiveEntry else { return NSWorkspace.shared.icon(forFile: hit.url.path) }
        let type = hit.isFolder ? UTType.folder : UTType(filenameExtension: (hit.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    static func highlighted(_ snippet: Snippet?) -> AttributedString {
        guard let snippet else { return AttributedString() }
        var text = AttributedString(snippet.text)
        if let range = Range(snippet.match, in: snippet.text), let span = Range(range, in: text) {
            text[span].foregroundColor = .primary
            text[span].font = .body.weight(.semibold)
        }
        return text
    }
}

/// Above the results in the duplicates view: what was found, and the way back.
struct DuplicatesBanner: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        let summary = model.duplicateSummary
        HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)
            Text("\(summary.files.formatted()) duplicate files in \(summary.sets.formatted()) "
                + (summary.sets == 1 ? "set" : "sets")
                + " · \(summary.reclaimable.formatted(.byteCount(style: .file))) in extra copies")
            Spacer()
            Button("Show All Results") { model.leaveDuplicates() }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.border).frame(height: 1)
        }
    }
}

struct ResultMenu: View {
    @Environment(SearchModel.self) private var model
    let ids: Set<FileHit.ID>

    var body: some View {
        if !ids.isEmpty {
            Button("Open") { model.open(ids) }
            Menu("Open With") {
                let applications = model.applications(toOpen: ids)
                ForEach(applications, id: \.self) { application in
                    Button(FileManager.default.displayName(atPath: application.path)) {
                        model.open(ids, with: application)
                    }
                }
                if !applications.isEmpty { Divider() }
                Button("Other…") { model.chooseApplicationAndOpen(ids) }
            }
            .disabled(model.openableURLs(ids).isEmpty)
            Button("Show in Finder") { model.reveal(ids) }
            Button("Quick Look") {
                model.previewURL = model.targets(ids).first
            }
            Divider()
            Button("Copy Path") { model.copyPaths(ids) }
            Button("Copy Rows") { model.copyRows(ids) }
            Divider()
            Button("Copy To…") { Task { await model.transfer(ids, .copy) } }
            Button("Move To…") { Task { await model.transfer(ids, .move) } }
            Button("Rename…") { model.requestRename(ids) }
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await model.trash(ids) } }
        }
    }
}

// MARK: - Status

struct StatusPill: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.isFindingDuplicates {
                ProgressView().controlSize(.small)
                Text("Finding duplicates…")
            } else {
                phaseStatus
            }
            if model.unreadable > 0 {
                Button {
                    SearchModel.openFullDiskAccessSettings()
                } label: {
                    Label("\(model.unreadable) unreadable", systemImage: "lock.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Some folders could not be read. Grant Full Disk Access to search them.")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.border).frame(height: 1)
        }
        .animation(.smooth, value: model.results.count)
    }

    @ViewBuilder private var phaseStatus: some View {
        switch model.phase {
        case .searching:
            ProgressView().controlSize(.small)
            Text("\(model.results.count.formatted()) matches · \(model.scanned.formatted()) scanned")
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(model.currentPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
        case .finished(let duration):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(model.results.count.formatted()) matches in \(Self.format(duration)) · \(model.scanned.formatted()) scanned")
                .monospacedDigit()
            if model.reachedLimit {
                Text("Stopped at the match limit — change it in Settings")
                    .foregroundStyle(.secondary)
            }
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
            Text("Stopped · \(model.results.count.formatted()) matches")
        case .idle, .failed:
            EmptyView()
        }
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }
}

extension Color {
    /// The window's dividing lines: brighter than the system separator, which all but disappears
    /// against the darkened glass. Light in dark mode, dark in light mode.
    static let border = Color(nsColor: NSColor(name: "FinderPlusBorder") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.2)
            : NSColor.black.withAlphaComponent(0.15)
    })
}
