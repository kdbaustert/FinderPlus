import AppKit
import Observation

/// Where a search starts. Identified by a path for folders and drives, and by an `@name` for the
/// scopes that resolve to a set of volumes or a folder only at search time.
enum SearchLocation: Identifiable, Hashable, Sendable {
    case allVolumes, localVolumes, removableVolumes, activeFinderWindow
    case folder(String)

    init(id: String) {
        switch id {
        // "" is how the first builds stored All Volumes.
        case "", "@all": self = .allVolumes
        case "@local": self = .localVolumes
        case "@removable": self = .removableVolumes
        case "@finder": self = .activeFinderWindow
        default: self = .folder(id)
        }
    }

    var id: String {
        switch self {
        case .allVolumes: "@all"
        case .localVolumes: "@local"
        case .removableVolumes: "@removable"
        case .activeFinderWindow: "@finder"
        case .folder(let path): path
        }
    }

    var path: String? {
        if case .folder(let path) = self { path } else { nil }
    }

    var title: String {
        switch self {
        case .allVolumes: "All Volumes"
        case .localVolumes: "Local Volumes"
        case .removableVolumes: "Removable Volumes"
        case .activeFinderWindow: "Active Finder Window"
        case .folder(let path):
            if path == NSHomeDirectory() { "Home" }
            else if path == Self.iCloudDrivePath { "iCloud Drive" }
            else { FileManager.default.displayName(atPath: path) }
        }
    }

    var symbol: String {
        let home = NSHomeDirectory()
        switch self {
        case .allVolumes: return "internaldrive"
        case .localVolumes: return "desktopcomputer"
        case .removableVolumes: return "externaldrive"
        case .activeFinderWindow: return "macwindow"
        case .folder(let path):
            switch path {
            case "/": return "internaldrive"
            case home: return "house"
            case home + "/Desktop": return "menubar.dock.rectangle"
            case home + "/Documents": return "doc"
            case home + "/Downloads": return "arrow.down.circle"
            case "/Applications": return "square.grid.3x3"
            case Self.iCloudDrivePath: return "icloud"
            default: return path.hasPrefix("/Volumes/") ? "externaldrive" : "folder"
            }
        }
    }

    var help: String {
        switch self {
        case .allVolumes: "Every mounted volume"
        case .localVolumes: "Every volume attached to this Mac, leaving out network shares"
        case .removableVolumes: "USB drives, SD cards and other ejectable volumes"
        case .activeFinderWindow: "The folder shown in the frontmost Finder window when the search starts"
        case .folder(let path): path
        }
    }

    static let iCloudDrivePath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    static let scopes: [SearchLocation] = [.allVolumes, .localVolumes, .removableVolumes]

    static let places: [SearchLocation] = {
        let home = NSHomeDirectory()
        return [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications"].map(folder)
    }()

    /// Mounted drives, then iCloud Drive when it is set up. Read fresh each time: drives come and go.
    static func drives() -> [SearchLocation] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let iCloud = FileManager.default.fileExists(atPath: iCloudDrivePath) ? [folder(iCloudDrivePath)] : []
        return volumes.map { folder($0.path) } + iCloud
    }
}

extension SearchLocation: Codable {
    /// Keyed as `path` because that is the shape the first builds stored.
    private enum CodingKeys: String, CodingKey { case path }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .path))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .path)
    }
}

enum LocationError: LocalizedError {
    case noRemovableVolumes
    case missingFolder(String)
    case finderAccessDenied
    case finderNotAFolder
    case finderTimedOut

    var errorDescription: String? {
        switch self {
        case .noRemovableVolumes:
            "No removable volumes are connected."
        case .missingFolder(let name):
            "“\(name)” isn’t available. Its drive may be disconnected, or the folder may have been moved or deleted."
        case .finderAccessDenied:
            "FinderPlus isn’t allowed to ask Finder which folder it’s showing. Allow it in System Settings › "
                + "Privacy & Security › Automation."
        case .finderNotAFolder:
            "The front Finder window isn’t showing a folder. Recents, AirDrop and search windows have no "
                + "location to search."
        case .finderTimedOut:
            "Finder didn’t answer. Try again once it’s responding."
        }
    }
}

/// The state every window shares and the Settings window edits: preferences, recent searches, and
/// the folders added to the Location menu. One instance backs every window's `SearchModel`, so a
/// change made anywhere shows everywhere at once — and so two windows never save stale copies of
/// the same list over each other's.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let settings = "settings"
        static let recents = "recentQueries"
        static let folders = "customFolders"
    }

    var settings: AppSettings { didSet { defaults.saveJSON(settings, Key.settings) } }
    private(set) var recentQueries: [String] { didSet { defaults.saveJSON(recentQueries, Key.recents) } }
    var customLocations: [SearchLocation] { didSet { defaults.saveJSON(customLocations, Key.folders) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.loadJSON(AppSettings.self, Key.settings) ?? AppSettings()
        recentQueries = defaults.loadJSON([String].self, Key.recents) ?? []
        customLocations = defaults.loadJSON([SearchLocation].self, Key.folders) ?? []
    }

    func remember(_ query: String) {
        guard settings.rememberRecents else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        recentQueries = [trimmed] + recentQueries.filter { $0 != trimmed }.prefix(11)
    }

    func clearRecents() {
        recentQueries = []
    }
}

@MainActor
@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle, searching, finished(Duration), stopped, failed(String)
    }

    private enum Key {
        static let options = "options"
        static let location = "location"
        static let sort = "sortOrder"
        static let preview = "showsPreview"
    }

    /// The app-wide state behind this window — see `Preferences`.
    let preferences: Preferences

    var query = ""
    var options: SearchOptions { didSet { save(options, Key.options) } }
    var locationID: String { didSet { save(locationID, Key.location) } }

    /// Passthroughs to the shared state, so every existing call site and binding keeps working.
    /// Computed, so `@Observable` views track the shared store itself rather than a copy here.
    var settings: AppSettings {
        get { preferences.settings }
        set { preferences.settings = newValue }
    }
    var customLocations: [SearchLocation] {
        get { preferences.customLocations }
        set { preferences.customLocations = newValue }
    }
    var recentQueries: [String] { preferences.recentQueries }

    var results: [FileHit] = []
    var selection: Set<FileHit.ID> = []
    var sortOrder: [KeyPathComparator<FileHit>] { didSet { saveSortOrder() } }
    /// True while the search field is being typed in, so ⌘⌫ deletes text there instead of
    /// moving the selected results to the Trash.
    var isEditingQuery = false
    var previewURL: URL?
    /// Bumped by ⌘F; the search field focuses itself when it changes.
    var focusRequest = 0
    /// Bumped by ↓ in the search field; the results table takes focus when it changes.
    var resultsFocusRequest = 0
    var showsSidebar = true

    private(set) var phase: Phase = .idle
    private(set) var scanned = 0
    private(set) var currentPath = ""
    private(set) var unreadable = 0
    /// Whether the results on screen came from a search that read inside files (contents or
    /// metadata), so they carry a snippet for the Match column.
    private(set) var searchedContents = false
    /// The last search stopped at the match limit from Settings.
    private(set) var reachedLimit = false
    /// The launch-time panel explaining Full Disk Access.
    var showsFullDiskAccessPrompt = false
    /// How the preview finds and marks matches: the matcher of the search on screen, when it read
    /// inside files, and whether that search read text out of images.
    private(set) var previewContext: PreviewContext?
    var showsPreview: Bool { didSet { defaults.set(showsPreview, forKey: Key.preview) } }

    struct PreviewContext: Sendable {
        let matcher: QueryMatcher
        let recognizeText: Bool
    }
    /// Duplicates view: each result's set number. Empty when showing ordinary results.
    private(set) var duplicateSets: [FileHit.ID: Int] = [:]
    private(set) var isFindingDuplicates = false
    @ObservationIgnored private var resultsBeforeDuplicates: [FileHit]?
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Where and how the results on screen were searched, so the next Find can tell whether it is
    /// refining them.
    @ObservationIgnored private var lastRun: Run?
    /// IDs already in `results`, so a hit carried over from the previous run is not added twice.
    @ObservationIgnored private var knownIDs: Set<FileHit.ID> = []

    /// What decides whether the rows on screen would all be found again: the folders actually
    /// walked (so a different front Finder window or an ejected drive counts as a change), the
    /// options, and the limits from Settings.
    private struct Run: Equatable {
        let roots: [String]
        let options: SearchOptions
        let limits: SearchLimits
    }

    init(defaults: UserDefaults = .standard, preferences: Preferences? = nil) {
        self.defaults = defaults
        self.preferences = preferences ?? Preferences(defaults: defaults)
        options = Self.load(SearchOptions.self, Key.options, defaults) ?? SearchOptions()
        locationID = Self.load(String.self, Key.location, defaults) ?? NSHomeDirectory()
        sortOrder = [Self.comparator(for: Self.load(SavedSort.self, Key.sort, defaults) ?? SavedSort())]
        showsPreview = defaults.bool(forKey: Key.preview)
    }

    var isSearching: Bool { phase == .searching }
    var location: SearchLocation { SearchLocation(id: locationID) }
    /// Set by ⌘L or "Select…"; the window presents a folder picker while it is true.
    var choosingFolder = false
    var selectedURLs: [URL] { targets(nil) }

    // MARK: - Searching

    /// Runs a search. Only Find (the button, Return in the field, or ⌘↩) calls this: typing, and
    /// changing options or the location, never start one on their own — a walk of the disk is too
    /// heavy to begin speculatively.
    func start() {
        // The same checks that disable the Find button, so Return cannot get around them. They run
        // before the running search is cancelled, so no early return can leave it cancelled but
        // still showing as searching.
        guard options.searchesAnyField else {
            searchTask?.cancel()
            showFailure("Choose what to search — Name, Contents, Tags or Comments — under Search for.")
            return
        }
        // The query is checked before the location is resolved, so an empty or invalid one never
        // asks Finder anything.
        do {
            _ = try QueryMatcher(query: query, options: options)
        } catch QueryError.empty {
            // Return in an emptied field ends the search on screen, spinner and all.
            stop()
            return
        } catch {
            searchTask?.cancel()
            showFailure(error.localizedDescription)
            return
        }

        searchTask?.cancel()
        remember(query)
        scanned = 0
        unreadable = 0
        reachedLimit = false
        currentPath = ""
        searchedContents = options.readsInsideFiles
        phase = .searching

        let (query, options, limits, location) = (query, options, settings.limits, location)
        let started = ContinuousClock.now
        searchTask = Task { [weak self] in
            let request: SearchRequest
            do {
                let roots = try await Self.resolveRoots(for: location)
                request = try SearchRequest(roots: roots, query: query, options: options, limits: limits)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showFailure(error.localizedDescription)
                return
            }
            // `self` is only ever unwrapped inside a scope that ends before the next suspension,
            // so a window closed mid-walk frees its model and the loop ends at the next event.
            let refine: (run: Run, rows: [FileHit])
            do {
                guard !Task.isCancelled, let self else { return }
                self.leaveDuplicates(restoring: false)
                self.previewContext = options.readsInsideFiles
                    ? PreviewContext(matcher: request.textMatcher, recognizeText: options.searchContents && options.recognizeText)
                    : nil
                refine = self.refinable(for: request)
            }
            // Off the main actor: one existence check per row stalls the window on a network volume.
            let rows = refine.rows
            let kept = await Self.offMain {
                rows.filter { !Task.isCancelled && FileManager.default.fileExists(atPath: $0.url.path) }
            }
            guard !Task.isCancelled else { return }
            self?.adopt(kept, for: refine.run)
            for await event in SearchEngine.run(request) {
                // Events already buffered when this search was stopped or replaced must not reach
                // the next search's results.
                guard !Task.isCancelled, let self else { break }
                self.apply(event)
            }
            guard !Task.isCancelled else { return }
            self?.phase = .finished(started.duration(to: .now))
        }
    }

    /// The rows on screen the new walk is certain to report again, still to be checked on disk.
    /// Content searches never keep rows — a kept row would keep the old query's snippet — and
    /// neither do searches with a match limit, which kept rows could push past. A row moved
    /// outside the roots since is not kept either: the walk would never report it. Nor is an
    /// archive entry: the zip still existing says nothing of the entry, and the walk re-lists it.
    private func refinable(for request: SearchRequest) -> (run: Run, rows: [FileHit]) {
        let run = Run(roots: request.roots.map(\.path), options: request.options, limits: request.limits)
        guard lastRun == run, run.options.searchNames, !run.options.readsInsideFiles, run.limits.maxResults == 0
        else { return (run, []) }
        let roots = run.roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let rows = results.filter { hit in
            !hit.isArchiveEntry && request.nameMatcher.matches(hit.name)
                && roots.contains { hit.url.path.hasPrefix($0) }
        }
        return (run, rows)
    }

    /// Starts the new run's rows from those kept. `lastRun` changes only here, together with the
    /// rows, so a search cancelled before this point cannot leave one run's rows filed under
    /// another. Sorted, because rows kept from the duplicates view arrive in set order.
    private func adopt(_ rows: [FileHit], for run: Run) {
        lastRun = run
        results = rows
        resort()
        knownIDs = Set(results.map(\.id))
        selection.formIntersection(knownIDs)
    }

    /// A failed search clears its rows, and the selection and duplicates view with them, so no
    /// toolbar action stays enabled — and no duplicates bar stays up — for rows that are gone.
    private func showFailure(_ message: String) {
        leaveDuplicates(restoring: false)
        results = []
        selection = []
        phase = .failed(message)
    }

    /// Runs `work` off the main actor, cancelled along with the task awaiting it: a bare
    /// `Task.detached` keeps running after its awaiter is cancelled.
    nonisolated private static func offMain<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        let task = Task.detached { work() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func stop() {
        guard isSearching else { return }
        searchTask?.cancel()
        searchTask = nil
        phase = .stopped
    }

    func resort() {
        results.sort(by: precedes)
    }

    // MARK: - Sort order

    /// The column and direction to restore at launch. `KeyPathComparator` is not Codable, so the
    /// first comparator is saved by the column it sorts.
    private struct SavedSort: Codable {
        enum Column: String, Codable { case name, location, match, kind, size, modified, created }
        var column = Column.name
        var ascending = true
    }

    private static func comparator(for saved: SavedSort) -> KeyPathComparator<FileHit> {
        let order: SortOrder = saved.ascending ? .forward : .reverse
        return switch saved.column {
        case .name: KeyPathComparator(\FileHit.name, order: order)
        case .location: KeyPathComparator(\FileHit.parentPath, order: order)
        case .match: KeyPathComparator(\FileHit.snippetText, order: order)
        case .kind: KeyPathComparator(\FileHit.kind, order: order)
        case .size: KeyPathComparator(\FileHit.size, order: order)
        case .modified: KeyPathComparator(\FileHit.modified, order: order)
        case .created: KeyPathComparator(\FileHit.created, order: order)
        }
    }

    private func saveSortOrder() {
        guard let first = sortOrder.first else { return }
        let columns: [(AnyKeyPath, SavedSort.Column)] = [
            (\FileHit.name, .name), (\FileHit.parentPath, .location), (\FileHit.snippetText, .match),
            (\FileHit.kind, .kind), (\FileHit.size, .size), (\FileHit.modified, .modified),
            (\FileHit.created, .created),
        ]
        guard let column = columns.first(where: { $0.0 == first.keyPath })?.1 else { return }
        save(SavedSort(column: column, ascending: first.order == .forward), Key.sort)
    }

    /// Merges a batch into the already-sorted results, so rows land in place as they are found
    /// rather than piling up at the bottom and jumping when the search ends. Each new row's place
    /// is found by binary search: comparing it against every row on screen instead fell behind the
    /// walk at around 200,000 results.
    private func insertSorted(_ hits: [FileHit]) {
        let batch = hits.filter { knownIDs.insert($0.id).inserted }.sorted(by: precedes)
        guard !batch.isEmpty else { return }
        var merged: [FileHit] = []
        merged.reserveCapacity(results.count + batch.count)
        var copied = 0
        for hit in batch {
            var low = copied, high = results.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(hit, results[middle]) { high = middle } else { low = middle + 1 }
            }
            merged += results[copied..<low]
            merged.append(hit)
            copied = low
        }
        merged += results[copied...]
        results = merged
    }

    private func precedes(_ a: FileHit, _ b: FileHit) -> Bool {
        for comparator in sortOrder {
            switch comparator.compare(a, b) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return false
    }

    private func apply(_ event: SearchEvent) {
        switch event {
        case .hits(let hits):
            insertSorted(hits)
        case .progress(let scanned, let current, let unreadable):
            self.scanned = scanned
            self.unreadable = unreadable
            currentPath = current
        case .limitReached:
            reachedLimit = true
        }
    }

    /// The folders a search walks. Async because the front Finder window has to be asked for, which
    /// happens off the main thread with a time limit.
    nonisolated static func resolveRoots(for location: SearchLocation) async throws -> [URL] {
        switch location {
        case .allVolumes:
            return volumes { _ in true }
        case .localVolumes:
            return volumes { $0.volumeIsLocal ?? true }
        case .removableVolumes:
            // USB drives usually report ejectable rather than removable; either counts.
            let roots = volumes { ($0.volumeIsRemovable ?? false) || ($0.volumeIsEjectable ?? false) }
            guard !roots.isEmpty else { throw LocationError.noRemovableVolumes }
            return roots
        case .activeFinderWindow:
            return [try await frontFinderFolder()]
        case .folder(let path):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw LocationError.missingFolder(location.title) }
            return [URL(filePath: path, directoryHint: .isDirectory)]
        }
    }

    /// `/` is among the mounted volumes; the walk skips `/Volumes`, so each other volume is walked
    /// once, from its own root.
    nonisolated private static func volumes(where include: (URLResourceValues) -> Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.filter { include((try? $0.resourceValues(forKeys: keys)) ?? URLResourceValues()) }
    }

    /// Resolved when the search starts, like EasyFind. Finder with no windows open means the
    /// Desktop, which is what Finder itself shows then. `osascript` on a background queue rather
    /// than `NSAppleScript` on the main thread: a busy Finder, or a permission prompt left
    /// unanswered, used to freeze the whole window for AppleScript's two-minute default.
    nonisolated private static func frontFinderFolder() async throws -> URL {
        let script = """
            tell application "Finder"
                if (count of Finder windows) is 0 then return POSIX path of (desktop as alias)
                return POSIX path of (target of front Finder window as alias)
            end tell
            """
        let path: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    continuation.resume(throwing: LocationError.finderTimedOut)
                    return
                }
                let deadline = Date.now.addingTimeInterval(8)
                while process.isRunning, Date.now < deadline { usleep(50_000) }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: LocationError.finderTimedOut)
                    return
                }
                let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: answer.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if problem.contains("-1743") {
                    // errAEEventNotPermitted: the Automation permission is off.
                    continuation.resume(throwing: LocationError.finderAccessDenied)
                } else {
                    continuation.resume(throwing: LocationError.finderNotAFolder)
                }
            }
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func remember(_ query: String) {
        preferences.remember(query)
    }

    func clearRecents() {
        preferences.clearRecents()
    }

    // MARK: - Locations

    func addFolders(_ urls: [URL]) {
        let known = Set((SearchLocation.places + SearchLocation.drives() + customLocations).map(\.id))
        let folders = urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { SearchLocation.folder($0.standardizedFileURL.path) }
        customLocations += folders.filter { !known.contains($0.id) }
        if let first = folders.first { locationID = first.id }
    }

    /// From Finder's service or the Dock icon: search in these folders. A file stands for the
    /// folder that holds it.
    func useFolders(_ urls: [URL]) {
        // Resolved first: a symlink to a folder reports isDirectory false, and would stand for
        // the folder that holds the link.
        let folders = urls.map { url in
            let resolved = url.resolvingSymlinksInPath()
            return (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? resolved : url.deletingLastPathComponent()
        }
        addFolders(folders)
        focusRequest += 1
    }

    func removeFolder(_ location: SearchLocation) {
        customLocations.removeAll { $0 == location }
        if locationID == location.id { locationID = NSHomeDirectory() }
    }

    // MARK: - File actions

    /// Renames, copies, moves and trashes still running, across every window. They run off the
    /// main thread, so quitting would kill one mid-batch — a rename's files stranded under hidden holding
    /// names — and the app delegate holds off quitting until this is back to zero. Counted until
    /// each action's last alert is dismissed, so a failure's explanation is read before the quit.
    static private(set) var batchesInFlight = 0 {
        didSet { if batchesInFlight == 0 { onBatchesDrained?() } }
    }
    static var onBatchesDrained: (() -> Void)?

    /// The rows for `ids`, or for the selection, in display order.
    func hits(_ ids: Set<FileHit.ID>?) -> [FileHit] {
        let ids = ids ?? selection
        guard !ids.isEmpty else { return [] }
        return results.filter { ids.contains($0.id) }
    }

    /// The files behind those rows, each once: a file inside an archive stands for its archive.
    func targets(_ ids: Set<FileHit.ID>?) -> [URL] {
        var seen = Set<URL>()
        return hits(ids).map(\.url).filter { seen.insert($0).inserted }
    }

    /// Double-clicking a result, as chosen in Settings.
    func performDefaultAction(_ ids: Set<FileHit.ID>) {
        switch settings.doubleClick {
        case .open: open(ids)
        case .reveal: reveal(ids)
        case .quickLook: previewURL = targets(ids).first
        }
    }

    func open(_ ids: Set<FileHit.ID>? = nil) {
        // An entry's archive is shown in Finder, not opened: Archive Utility would extract all of
        // it beside the zip to get at one file. Trash declines entries for the same reason.
        let rows = hits(ids)
        var seen = Set<URL>()
        for url in rows.filter({ !$0.isArchiveEntry }).map(\.url) where seen.insert(url).inserted {
            NSWorkspace.shared.open(url)
        }
        let archives = rows.filter(\.isArchiveEntry).map(\.url).filter { seen.insert($0).inserted }
        if !archives.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(archives) }
    }

    func reveal(_ ids: Set<FileHit.ID>? = nil) {
        Self.revealInNewWindow(targets(ids))
    }

    /// Shows the files selected in a new Finder window, one window per containing folder.
    /// `activateFileViewerSelecting` reuses any window already showing the folder, yanking it to
    /// the front and away from whatever the user had it on; scripting Finder is the only way to
    /// insist on a fresh window (tabs are not scriptable at all). This rides the same Automation
    /// permission the Active Finder Window location asks for; when it is off, or Finder stalls
    /// past the deadline, fall back to the reusing behavior rather than showing nothing.
    nonisolated private static func revealInNewWindow(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var parents: [URL] = []
        var grouped: [URL: [URL]] = [:]
        for url in urls {
            let parent = url.deletingLastPathComponent()
            if grouped[parent] == nil { parents.append(parent) }
            grouped[parent, default: []].append(url)
        }
        func quoted(_ url: URL) -> String {
            let escaped = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "(POSIX file \"\(escaped)\" as alias)"
        }
        var lines = ["tell application \"Finder\"", "activate"]
        for parent in parents {
            lines.append("make new Finder window to \(quoted(parent))")
            lines.append("select {\(grouped[parent, default: []].map(quoted).joined(separator: ", "))}")
        }
        lines.append("end tell")
        let script = lines.joined(separator: "\n")
        DispatchQueue.global(qos: .userInitiated).async {
            let fallBack: () -> Void = { Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting(urls) } }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch {
                fallBack()
                return
            }
            let deadline = Date.now.addingTimeInterval(8)
            while process.isRunning, Date.now < deadline { usleep(50_000) }
            if process.isRunning {
                process.terminate()
                fallBack()
            } else if process.terminationStatus != 0 {
                fallBack()
            }
        }
    }

    func copyPaths(_ ids: Set<FileHit.ID>? = nil) {
        let rows = hits(ids)
        guard !rows.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rows.map(\.fullPath).joined(separator: "\n"), forType: .string)
    }

    func toggleQuickLook() {
        previewURL = previewURL == nil ? targets(nil).first : nil
    }

    func trash(_ ids: Set<FileHit.ID>? = nil) async {
        // Only files on disk: a file inside an archive cannot be trashed on its own, and trashing
        // the archive because one entry was selected would take everything else in it too.
        var seen = Set<URL>()
        let urls = hits(ids).filter { !$0.isArchiveEntry }.map(\.url).filter { seen.insert($0).inserted }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        if settings.confirmTrash {
            let alert = NSAlert()
            alert.messageText = "Move \(Self.describe(urls)) to the Trash?"
            alert.informativeText = "You can put it back from the Trash in Finder."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Self.batchesInFlight += 1
        defer { Self.batchesInFlight -= 1 }
        let outcome = await Self.recycle(urls)
        results.removeAll { outcome.trashed.contains($0.url) }
        let remaining = Set(results.map(\.id))
        selection.formIntersection(remaining)
        knownIDs.formIntersection(remaining)

        let refused = urls.filter { !outcome.trashed.contains($0) }
        guard !refused.isEmpty, !outcome.failed.isEmpty else { return }
        if outcome.deniedByPermissions {
            explainPermission(toDo: "delete", refused, failures: outcome.failed)
        } else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t move \(Self.describe(refused)) to the Trash"
            alert.informativeText = outcome.failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    private struct RecycleOutcome: Sendable {
        var trashed: Set<URL>
        var failed: [String] = []
        var deniedByPermissions = false
    }

    /// The completion-handler form rather than `async throws`: that one throws away the files that
    /// did reach the Trash whenever any file in the batch fails. It reports one error for the
    /// batch, so each refused file is explained against it separately.
    private static func recycle(_ urls: [URL]) async -> RecycleOutcome {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                var outcome = RecycleOutcome(trashed: Set(moved.keys))
                if let error {
                    for url in urls where moved[url] == nil {
                        let refusal = failure(error, of: url)
                        outcome.failed.append(refusal.line)
                        if refusal.needsAccess { outcome.deniedByPermissions = true }
                    }
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    nonisolated static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        let cocoa = error.domain == NSCocoaErrorDomain
            && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
        let posix = error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionError) ?? false
        return cocoa || posix || underlying
    }

    /// Finder's Locked checkbox (or `chflags uchg`). A locked item is refused with the same EPERM
    /// as a protected place, but Full Disk Access cannot unlock it, so it gets its own reason.
    nonisolated static func isLocked(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUserImmutableKey, .isSystemImmutableKey])
        return values?.isUserImmutable == true || values?.isSystemImmutable == true
    }

    /// One refused item's line for an alert, and whether Full Disk Access could fix it. `item` is
    /// where the file is now, for the lock check; `name` is what the user knows it as.
    nonisolated static func failure(
        _ error: any Error, of item: URL, named name: String? = nil
    ) -> (line: String, needsAccess: Bool) {
        let name = name ?? item.lastPathComponent
        if isLocked(item) {
            return ("\(name): The item is locked. Unlock it in its Get Info window in Finder.", false)
        }
        return ("\(name): \(error.localizedDescription)", isPermissionError(error))
    }

    /// macOS refuses to trash files in protected places until FinderPlus has Full Disk Access; files
    /// owned by the system need Finder, which can ask for an administrator password. Every failure
    /// in the batch is listed, not just the ones access would fix.
    private func explainPermission(toDo verb: String, _ urls: [URL], failures: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "FinderPlus needs Full Disk Access to \(verb) \(Self.describe(urls))"
        alert.informativeText = failures.joined(separator: "\n") + "\n\n" + """
            macOS blocked this. Turn on FinderPlus in System Settings › Privacy & \
            Security › Full Disk Access, then try again.

            Files that belong to macOS itself can only be deleted in Finder, which asks for an \
            administrator password.
            """
        alert.addButton(withTitle: "Open Full Disk Access Settings")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Self.openFullDiskAccessSettings()
        case .alertSecondButtonReturn:
            Self.revealInNewWindow(urls)
        default:
            break
        }
    }

    // MARK: - Export

    /// The results as CSV, in the order shown. The byte-order mark makes Excel read it as UTF-8;
    /// Numbers ignores it.
    func resultsCSV(_ rows: [FileHit]? = nil) -> String {
        let dates = ISO8601DateFormatter()
        func date(_ value: Date) -> String { value == .distantPast ? "" : dates.string(from: value) }
        var lines = ["Name,Location,Kind,Size,Date Modified,Date Created,Match"]
        for hit in rows ?? results {
            let fields = [
                hit.name, hit.parentPath, hit.kind, hit.size < 0 ? "" : String(hit.size),
                date(hit.modified), date(hit.created), hit.snippetText,
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func exportResults() {
        guard !results.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "FinderPlus Results.csv"
        panel.message = "Export \(results.count.formatted()) results as a spreadsheet"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try resultsCSV().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Rows as tab-separated text, which pastes into Numbers or Excel as a table.
    func copyRows(_ ids: Set<FileHit.ID>? = nil) {
        let rows = hits(ids)
        guard !rows.isEmpty else { return }
        let header = "Name\tLocation\tKind\tSize\tDate Modified"
        let lines = rows.map { hit in
            [hit.name, hit.parentPath, hit.kind, hit.sizeText, hit.modified.formatted(date: .abbreviated, time: .shortened)]
                .joined(separator: "\t")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(([header] + lines).joined(separator: "\n"), forType: .string)
    }

    // MARK: - Open With, Copy To, Move To

    /// Apps that can open the first of the rows, the default one first.
    func applications(toOpen ids: Set<FileHit.ID>?) -> [URL] {
        guard let first = targets(ids).first else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: first)
    }

    func open(_ ids: Set<FileHit.ID>?, with application: URL) {
        let urls = targets(ids)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseApplicationAndOpen(_ ids: Set<FileHit.ID>?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let application = panel.url else { return }
        open(ids, with: application)
    }

    enum Transfer: Sendable {
        case copy, move

        var verb: String { self == .copy ? "copy" : "move" }
    }

    struct TransferOutcome: Sendable {
        var done: [URL: URL] = [:]
        var failed: [String] = []
        var deniedByPermissions = false
    }

    /// Copies or moves the rows' files into a folder the user picks. Runs off the main thread, so
    /// a large copy does not freeze the window; an existing name gets " 2", " 3" rather than
    /// being overwritten. Files inside archives are skipped: they have no file of their own.
    func transfer(_ ids: Set<FileHit.ID>? = nil, _ kind: Transfer) async {
        var seen = Set<URL>()
        let sources = hits(ids).filter { !$0.isArchiveEntry }.map(\.url).filter { seen.insert($0).inserted }
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = kind == .copy ? "Copy Here" : "Move Here"
        panel.message = "Choose where to \(kind.verb) \(Self.describe(sources))"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Self.batchesInFlight += 1
        defer { Self.batchesInFlight -= 1 }
        let outcome = await Task.detached { Self.perform(kind, sources, into: destination) }.value
        if kind == .move, !outcome.done.isEmpty {
            // The same follow-the-file update a rename gets: rows inside a moved folder — and
            // entries inside a moved archive — follow it rather than pointing at the old paths.
            relocateRows(after: outcome)
        }
        guard !outcome.failed.isEmpty else { return }
        let refused = sources.filter { outcome.done[$0] == nil }
        if outcome.deniedByPermissions {
            explainPermission(toDo: kind.verb, refused, failures: outcome.failed)
        } else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t \(kind.verb) \(Self.describe(refused))"
            alert.informativeText = outcome.failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    nonisolated static func perform(_ kind: Transfer, _ sources: [URL], into folder: URL) -> TransferOutcome {
        var outcome = TransferOutcome()
        for source in sources {
            let target = availableName(for: source.lastPathComponent, in: folder)
            do {
                switch kind {
                case .copy: try FileManager.default.copyItem(at: source, to: target)
                case .move: try FileManager.default.moveItem(at: source, to: target)
                }
                outcome.done[source] = target
            } catch {
                let refusal = failure(error, of: source)
                outcome.failed.append(refusal.line)
                if refusal.needsAccess { outcome.deniedByPermissions = true }
            }
        }
        return outcome
    }

    /// "Report.pdf", then "Report 2.pdf", "Report 3.pdf" — Finder's convention.
    nonisolated static func availableName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // MARK: - Rename

    /// The rows the Rename sheet is open for, or nil.
    var renameRequest: RenameRequest?

    /// Opens the Rename sheet for the rows, or the selection. Entries inside archives are left
    /// out: they have no file of their own to rename.
    func requestRename(_ ids: Set<FileHit.ID>? = nil) {
        let files = hits(ids).filter { !$0.isArchiveEntry }
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        renameRequest = RenameRequest(hits: files)
    }

    /// Renames files in place, then updates their rows — selection included, so the renamed files
    /// stay selected under their new IDs.
    func rename(_ steps: [RenameStep]) async {
        guard !steps.isEmpty else { return }
        Self.batchesInFlight += 1
        defer { Self.batchesInFlight -= 1 }
        let outcome = await Task.detached { Self.performRename(steps) }.value
        if !outcome.done.isEmpty {
            relocateRows(after: outcome)
        }
        guard !outcome.failed.isEmpty else { return }
        // Where each file is now: the batch is undone, bar any file the alert says ended elsewhere.
        let items = steps.map { outcome.done[$0.source] ?? $0.source }
        if outcome.deniedByPermissions {
            explainPermission(toDo: "rename", items, failures: outcome.failed)
        } else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t rename \(Self.describe(items))"
            alert.informativeText = outcome.failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Rows, selection and the duplicates view after files renamed or moved on disk: every row
    /// under a changed path follows it, staying selected and keeping its duplicate-set number
    /// under its new ID.
    func relocateRows(after outcome: TransferOutcome) {
        let renamed = Dictionary(uniqueKeysWithValues: outcome.done.map { ($0.key.path, $0.value.path) })
        let before = results
        results = Self.relocate(results, renamed)
        let newIDs = Dictionary(zip(before.map(\.id), results.map(\.id))) { first, _ in first }
        selection = Set(selection.map { newIDs[$0] ?? $0 })
        knownIDs = Set(results.map(\.id))
        resultsBeforeDuplicates = resultsBeforeDuplicates.map { Self.relocate($0, renamed) }
        if showsDuplicates {
            // Relocated rows keep their set number, and the rows stay grouped the way Find
            // Duplicates lays them out rather than scattering under the sorted column. A shown
            // row wins the collision when its new path is the lingering key of a row trashed
            // from the view, so its set number never depends on dictionary order.
            var sets: [FileHit.ID: Int] = [:]
            for (id, number) in duplicateSets where newIDs[id] == nil { sets[id] = number }
            for (old, new) in newIDs { if let number = duplicateSets[old] { sets[new] = number } }
            duplicateSets = sets
            results.sort { (duplicateSets[$0.id] ?? 0, $0.name) < (duplicateSets[$1.id] ?? 0, $1.name) }
        } else {
            resort()
        }
    }

    /// Rows after a rename: a renamed file's row takes its new name, and every row inside a
    /// renamed folder or archive has that part of its path rewritten. Left stale, a row resolves
    /// to whatever took the old path — after two folders swap names, the other folder's file.
    private static func relocate(_ hits: [FileHit], _ renamed: [String: String]) -> [FileHit] {
        hits.map { hit in
            let path = hit.url.path
            var ancestor = path
            while !ancestor.isEmpty, ancestor != "/" {
                if let moved = renamed[ancestor] {
                    let url = URL(
                        filePath: moved + (path as NSString).substring(from: (ancestor as NSString).length),
                        directoryHint: hit.url.hasDirectoryPath ? .isDirectory : .notDirectory)
                    let isOwnRow = ancestor == path && !hit.isArchiveEntry
                    return FileHit(
                        url: url, archiveEntry: hit.archiveEntry, name: isOwnRow ? url.lastPathComponent : hit.name,
                        isFolder: hit.isFolder, size: hit.size, modified: hit.modified, created: hit.created,
                        kind: hit.kind, snippet: hit.snippet)
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return hit
        }
    }

    /// Every file is parked under a temporary name before any lands under its new one, so a batch
    /// that permutes names — renumbering 1, 2, 3 the other way round — never collides with a file
    /// later in the same batch. All or nothing: the first failure undoes every step in reverse,
    /// because by then an earlier step may hold the failed file's old name, and half a
    /// renumbering is worse than none. `done` says where each file ended up.
    nonisolated static func performRename(_ steps: [RenameStep]) -> TransferOutcome {
        let manager = FileManager.default
        var parked: [(holding: URL, step: RenameStep)] = []
        var landed = 0
        var cause: (line: String, needsAccess: Bool)?
        // Cocoa's messages name the file being moved, which in pass two is the hidden holding name.
        func explain(_ error: any Error, at item: URL, parkedAs holding: URL, for step: RenameStep)
            -> (line: String, needsAccess: Bool)
        {
            let name = step.source.lastPathComponent
            let refusal = failure(error, of: item, named: name)
            return (refusal.line.replacingOccurrences(of: holding.lastPathComponent, with: name), refusal.needsAccess)
        }
        for step in steps {
            let holding = step.source.deletingLastPathComponent()
                .appending(path: ".FinderPlus-rename-" + UUID().uuidString)
            do {
                try manager.moveItem(at: step.source, to: holding)
                parked.append((holding, step))
            } catch {
                cause = explain(error, at: step.source, parkedAs: holding, for: step)
                break
            }
        }
        if cause == nil {
            for (holding, step) in parked {
                do {
                    try manager.moveItem(at: holding, to: step.target)
                    landed += 1
                } catch {
                    cause = explain(error, at: holding, parkedAs: holding, for: step)
                    break
                }
            }
        }
        var outcome = TransferOutcome()
        guard let cause else {
            for (_, step) in parked { outcome.done[step.source] = step.target }
            return outcome
        }
        outcome.failed.append(cause.line)
        outcome.deniedByPermissions = cause.needsAccess

        // Landed files go back to their holding names first, so every name the batch took is free
        // again before any file is unparked.
        var stayedRenamed = Set<Int>()
        for index in (0..<landed).reversed() {
            let (holding, step) = parked[index]
            do {
                try manager.moveItem(at: step.target, to: holding)
            } catch {
                stayedRenamed.insert(index)
                outcome.done[step.source] = step.target
                outcome.failed.append(
                    "“\(step.source.lastPathComponent)” couldn’t be put back, so it keeps its new name "
                        + "“\(step.target.lastPathComponent)”.")
            }
        }
        // Never a silent `try?`: if the old name is taken, a free visible name beside it is the
        // fallback, so no file is ever left hidden without the alert saying so.
        for index in parked.indices.reversed() where !stayedRenamed.contains(index) {
            let (holding, step) = parked[index]
            let name = step.source.lastPathComponent
            let folder = step.source.deletingLastPathComponent()
            do {
                try manager.moveItem(at: holding, to: step.source)
            } catch {
                let fallback = availableName(for: name, in: folder)
                do {
                    try manager.moveItem(at: holding, to: fallback)
                    outcome.done[step.source] = fallback
                    outcome.failed.append(
                        "“\(name)” couldn’t get its old name back, so it is now “\(fallback.lastPathComponent)”.")
                } catch {
                    // The one message that names the holding file: without it, nobody could find it.
                    outcome.failed.append(
                        "“\(name)” couldn’t be put back. It is hidden in \(folder.path) as "
                            + "“\(holding.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }
        if outcome.failed.count == 1, steps.count > 1 {
            outcome.failed.append("Nothing was renamed: every item keeps its old name.")
        }
        return outcome
    }

    // MARK: - Duplicates

    var showsDuplicates: Bool { !duplicateSets.isEmpty }

    /// How many sets, how many files in them, and the space the extra copies take.
    var duplicateSummary: (sets: Int, files: Int, reclaimable: Int64) {
        let members = results.compactMap { hit in duplicateSets[hit.id].map { (number: $0, hit: hit) } }
        let sets = Dictionary(grouping: members, by: \.number)
        let reclaimable = sets.values.reduce(Int64(0)) { total, set in
            total + Int64(set.count - 1) * max(set.first?.hit.size ?? 0, 0)
        }
        return (sets.count, members.count, reclaimable)
    }

    /// Narrows the results to files whose contents match another result's, grouped into sets.
    func findDuplicates() {
        guard !isSearching, !isFindingDuplicates else { return }
        let base = resultsBeforeDuplicates ?? results
        let candidates = base.filter { !$0.isFolder && !$0.isArchiveEntry && $0.size > 0 }
            .map { DuplicateFinder.Candidate(id: $0.id, url: $0.url, size: $0.size) }
        guard candidates.count > 1 else {
            NSSound.beep()
            return
        }
        isFindingDuplicates = true
        duplicateTask = Task { [weak self] in
            // Cancelled with this task, so a new search stops the hashing rather than outliving it.
            let sets = await Self.offMain { DuplicateFinder.sets(in: candidates) }
            guard let self, !Task.isCancelled else { return }
            isFindingDuplicates = false
            guard !sets.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No duplicates"
                alert.informativeText = "None of these \(candidates.count.formatted()) files have the same contents as another."
                alert.runModal()
                return
            }
            var numbers: [FileHit.ID: Int] = [:]
            for (index, set) in sets.enumerated() {
                for id in set { numbers[id] = index + 1 }
            }
            resultsBeforeDuplicates = base
            duplicateSets = numbers
            results = base.filter { numbers[$0.id] != nil }
                .sorted { (numbers[$0.id]!, $0.name) < (numbers[$1.id]!, $1.name) }
            selection.formIntersection(Set(results.map(\.id)))
        }
    }

    /// Back to the full results. A new search leaves without restoring: it replaces them.
    func leaveDuplicates(restoring: Bool = true) {
        duplicateTask?.cancel()
        isFindingDuplicates = false
        guard let before = resultsBeforeDuplicates else { return }
        if restoring {
            // Rows trashed or moved while viewing duplicates stay gone; moved ones come back at
            // their new location.
            let shown = Set(results.map(\.id))
            let removed = Set(duplicateSets.keys).subtracting(shown)
            let beforeIDs = Set(before.map(\.id))
            results = before.filter { !removed.contains($0.id) } + results.filter { !beforeIDs.contains($0.id) }
            knownIDs = Set(results.map(\.id))
            resort()
        }
        resultsBeforeDuplicates = nil
        duplicateSets = [:]
    }

    // MARK: - Full Disk Access

    /// Only the first window checks: without the gate, every window opened with ⌘N would raise
    /// the explanation sheet again until access was granted.
    private static var checkedAccessThisLaunch = false

    func checkFullDiskAccessAtLaunch() {
        guard !Self.checkedAccessThisLaunch else { return }
        Self.checkedAccessThisLaunch = true
        showsFullDiskAccessPrompt = !Self.hasFullDiskAccess()
    }

    /// Returning from System Settings: the panel closes itself once access is on.
    func recheckFullDiskAccess() {
        if showsFullDiskAccessPrompt && Self.hasFullDiskAccess() {
            showsFullDiskAccessPrompt = false
        }
    }

    /// macOS offers no call that answers this, so it is tested directly: these files exist on every
    /// Mac and open only with Full Disk Access. A missing file is skipped; a refusal means no
    /// access. When nothing can be tested the answer is yes, so the app never nags without cause.
    nonisolated static func hasFullDiskAccess(probing probes: [String] = fullDiskAccessProbes) -> Bool {
        for path in probes {
            let descriptor = Darwin.open(path, O_RDONLY)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true
    }

    nonisolated static let fullDiskAccessProbes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
    }()

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    // MARK: - Persistence

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.saveJSON(value, key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, _ defaults: UserDefaults) -> Value? {
        defaults.loadJSON(type, key)
    }
}

extension UserDefaults {
    fileprivate func saveJSON<Value: Encodable>(_ value: Value, _ key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }

    fileprivate func loadJSON<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
