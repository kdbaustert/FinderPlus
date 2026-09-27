import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A glass toolbar over two floating Liquid Glass panels — search options and results — on a
/// translucent window and a soft colour field, so the glass has something to refract. A split view
/// is not used: its sidebar is an opaque system panel that cannot be given a glass shape of our own.
struct ContentView: View {
    @Environment(SearchModel.self) private var model

    var body: some View {
        ZStack {
            // Under the toolbar too, so its glass has colour behind it.
            AmbientBackdrop().ignoresSafeArea()
            HStack(spacing: 10) {
                if model.showsSidebar {
                    OptionsPanel()
                        .frame(width: 244)
                        .glassPanel()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ResultsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaBar(edge: .top) { SearchHeader() }
                    .overlay(alignment: .bottom) {
                        if model.phase != .idle, !isFailed {
                            StatusPill()
                                .padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.35), value: model.phase)
                    .glassPanel()
            }
            .padding([.horizontal, .bottom], 10)
            .padding(.top, 4)
        }
        .containerBackground(.thinMaterial, for: .window)
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

        // Everything here acts on the selected results, and sits idle until there are some.
        ToolbarItemGroup(placement: .primaryAction) {
            action("Quick Look", symbol: "eye", help: "Quick Look (Space)") { model.toggleQuickLook() }
            action("Open", symbol: "arrow.up.forward.app", help: "Open (⌘O)") { model.open() }
            action("Show in Finder", symbol: "folder", help: "Show in Finder (⌘R)") { model.reveal() }
            action("Copy Path", symbol: "doc.on.doc", help: "Copy Path (⌥⌘C)") { model.copyPaths() }
        }
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

extension View {
    /// A floating Liquid Glass panel. Content is clipped to the same shape so table rows and
    /// scroll edges stop at the rounded corners instead of poking past the glass.
    func glassPanel(cornerRadius: CGFloat = 24) -> some View {
        clipShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Static colour behind the panels. Glass over a flat fill reads as grey plastic; it needs light
/// and colour underneath to look like glass. Rendered once — nothing here animates.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Circle().fill(Color.accentColor)
                    .frame(width: size.width * 0.55)
                    .position(x: size.width * 0.12, y: size.height * 0.1)
                Circle().fill(Color.purple)
                    .frame(width: size.width * 0.5)
                    .position(x: size.width * 0.9, y: size.height * 0.95)
                Circle().fill(Color.teal)
                    .frame(width: size.width * 0.4)
                    .position(x: size.width * 0.75, y: size.height * 0.05)
            }
            .blur(radius: 110)
            .opacity(colorScheme == .dark ? 0.45 : 0.3)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Search header

struct SearchHeader: View {
    @Environment(SearchModel.self) private var model
    @FocusState private var fieldFocused: Bool
    @Namespace private var glass

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            GlassEffectContainer(spacing: 12) {
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
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("field", in: glass)

                    if model.isSearching {
                        Button(role: .cancel) { model.stop() } label: {
                            Label("Stop", systemImage: "stop.fill").padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                        .glassEffectID("action", in: glass)
                    } else {
                        Button { model.start() } label: {
                            Label("Find", systemImage: "arrow.forward").padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || !model.options.searchesAnyField)
                        .glassEffectID("action", in: glass)
                    }
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
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(.smooth(duration: 0.3), value: model.isSearching)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.showsSidebar)
        .onChange(of: model.focusRequest) { fieldFocused = true }
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
                    Divider().padding(.vertical, 2)
                    Toggle("Name", isOn: $model.options.searchNames)
                    Toggle("Contents", isOn: $model.options.searchContents)
                        .help("Read inside text files, PDFs and word-processor documents.")
                    Toggle("Tags", isOn: $model.options.searchTags)
                    Toggle("Comments", isOn: $model.options.searchComments)
                        .help("The comment from Finder’s Get Info window")
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

                OptionSection("Include") {
                    Toggle("Package Contents", isOn: $model.options.includePackageContents)
                        .help("Look inside apps, bundles and other packages")
                    Toggle("Invisible Files & Folders", isOn: $model.options.includeHidden)
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
            .padding(.top, 16)
            .padding(.bottom, 16)
            .animation(.snappy, value: model.options)
        }
        .scrollIndicators(.never)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFolders(urls)
            return true
        }
    }
}

/// A titled group of options on a subtle card, in the manner of System Settings.
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
            .padding(10)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
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
        @Bindable var model = model
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
        // Overlaid rather than in the label: the glass menu button keeps only a label's icon and title.
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        }
        .help(model.location.help)
        .fileImporter(isPresented: $model.choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addFolders([url]) }
        }
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
        table
            .opacity(model.results.isEmpty ? 0 : 1)
            .allowsHitTesting(!model.results.isEmpty)
            .overlay {
                if model.results.isEmpty { placeholder }
            }
        .quickLookPreview($model.previewURL, in: model.selectedURLs)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: FileHit.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { hit in
                HStack(spacing: 7) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: hit.url.path))
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
                    Text(hit.displayParent)
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

        } rows: {
            ForEach(model.results) { hit in
                TableRow(hit).draggable(hit.url)
            }
        }
        // Transparent, so rows sit directly on the panel's glass.
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .focused($tableFocused)
        .onChange(of: model.resultsFocusRequest) {
            tableFocused = true
            if model.selection.isEmpty, let first = model.results.first { model.selection = [first.id] }
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            ResultMenu(ids: ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onDeleteCommand { Task { await model.trash() } }
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

    static func highlighted(_ snippet: Snippet?) -> AttributedString {
        guard let snippet else { return AttributedString() }
        var text = AttributedString(snippet.text)
        if let range = Range(snippet.match, in: snippet.text), let span = Range(range, in: text) {
            text[span].foregroundColor = .primary
            text[span].backgroundColor = Color.accentColor.opacity(0.25)
            text[span].font = .body.weight(.semibold)
        }
        return text
    }
}

struct ResultMenu: View {
    @Environment(SearchModel.self) private var model
    let ids: Set<URL>

    var body: some View {
        if !ids.isEmpty {
            Button("Open") { model.open(ids) }
            Button("Show in Finder") { model.reveal(ids) }
            Button("Quick Look") {
                model.previewURL = model.targets(ids).first
            }
            Divider()
            Button("Copy Path") { model.copyPaths(ids) }
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
            case .stopped:
                Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
                Text("Stopped · \(model.results.count.formatted()) matches")
            case .idle, .failed:
                EmptyView()
            }
            if model.unreadable > 0 {
                Button {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    if let url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("\(model.unreadable) unreadable", systemImage: "lock.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Some folders could not be read. Grant Full Disk Access to search them.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth, value: model.results.count)
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }
}
