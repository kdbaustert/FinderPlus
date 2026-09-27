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

@MainActor
@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle, searching, finished(Duration), stopped, failed(String)
    }

    private enum Key {
        static let options = "options"
        static let folders = "customFolders"
        static let location = "location"
        static let recents = "recentQueries"
        static let settings = "settings"
        static let sort = "sortOrder"
    }

    var query = ""
    var options: SearchOptions { didSet { save(options, Key.options) } }
    var customLocations: [SearchLocation] { didSet { save(customLocations, Key.folders) } }
    var locationID: String { didSet { save(locationID, Key.location) } }
    private(set) var recentQueries: [String] { didSet { save(recentQueries, Key.recents) } }
    var settings: AppSettings { didSet { save(settings, Key.settings) } }

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
    /// Whether the results on screen came from a search that read file contents.
    private(set) var searchedContents = false
    /// The last search stopped at the match limit from Settings.
    private(set) var reachedLimit = false
    /// The launch-time panel explaining Full Disk Access.
    var showsFullDiskAccessPrompt = false

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = Self.load(SearchOptions.self, Key.options, defaults) ?? SearchOptions()
        customLocations = Self.load([SearchLocation].self, Key.folders, defaults) ?? []
        locationID = Self.load(String.self, Key.location, defaults) ?? NSHomeDirectory()
        recentQueries = Self.load([String].self, Key.recents, defaults) ?? []
        settings = Self.load(AppSettings.self, Key.settings, defaults) ?? AppSettings()
        sortOrder = [Self.comparator(for: Self.load(SavedSort.self, Key.sort, defaults) ?? SavedSort())]
    }

    var isSearching: Bool { phase == .searching }
    var location: SearchLocation { SearchLocation(id: locationID) }
    /// Set by ⌘L or "Select…"; the Location menu presents a folder picker while it is true.
    var choosingFolder = false
    var selectedURLs: [URL] { targets(nil) }

    // MARK: - Searching

    /// Runs a search. Only Find (the button, Return in the field, or ⌘↩) calls this: typing, and
    /// changing options or the location, never start one on their own — a walk of the disk is too
    /// heavy to begin speculatively.
    func start() {
        searchTask?.cancel()
        // The same checks that disable the Find button, so Return cannot get around them.
        guard options.searchesAnyField else {
            results = []
            phase = .failed("Choose what to search — Name, Contents, Tags or Comments — under Search for.")
            return
        }
        // The query is checked before the location is resolved, so an empty or invalid one never
        // asks Finder anything.
        do {
            _ = try QueryMatcher(query: query, options: options)
        } catch QueryError.empty {
            return
        } catch {
            results = []
            phase = .failed(error.localizedDescription)
            return
        }

        remember(query)
        scanned = 0
        unreadable = 0
        reachedLimit = false
        currentPath = ""
        searchedContents = options.searchContents
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
                self?.results = []
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard !Task.isCancelled, let self else { return }
            prepareResults(for: request)
            for await event in SearchEngine.run(request) {
                // Events already buffered when this search was stopped or replaced must not reach
                // the next search's results.
                guard !Task.isCancelled else { break }
                apply(event)
            }
            guard !Task.isCancelled else { return }
            phase = .finished(started.duration(to: .now))
        }
    }

    /// Narrows the rows on screen when the new walk is certain to report them again; otherwise
    /// clears them. Content searches never keep rows — a kept row would keep the old query's
    /// snippet — and neither do searches with a match limit, which kept rows could push past.
    private func prepareResults(for request: SearchRequest) {
        let run = Run(roots: request.roots.map(\.path), options: request.options, limits: request.limits)
        let refinesLast = lastRun == run
        lastRun = run
        if refinesLast, run.options.searchNames, !run.options.searchContents, run.limits.maxResults == 0 {
            results.removeAll {
                !request.nameMatcher.matches($0.name) || !FileManager.default.fileExists(atPath: $0.url.path)
            }
        } else {
            results = []
        }
        knownIDs = Set(results.map(\.id))
        selection.formIntersection(knownIDs)
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
        guard settings.rememberRecents else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        recentQueries = [trimmed] + recentQueries.filter { $0 != trimmed }.prefix(11)
    }

    func clearRecents() {
        recentQueries = []
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

    func removeFolder(_ location: SearchLocation) {
        customLocations.removeAll { $0 == location }
        if locationID == location.id { locationID = NSHomeDirectory() }
    }

    // MARK: - File actions

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
        for url in targets(ids) { NSWorkspace.shared.open(url) }
    }

    func reveal(_ ids: Set<FileHit.ID>? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(targets(ids))
    }

    func copyPaths(_ ids: Set<FileHit.ID>? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hits(ids).map(\.fullPath).joined(separator: "\n"), forType: .string)
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
        let outcome = await Self.recycle(urls)
        results.removeAll { outcome.trashed.contains($0.url) }
        let remaining = Set(results.map(\.id))
        selection.formIntersection(remaining)
        knownIDs.formIntersection(remaining)

        let refused = urls.filter { !outcome.trashed.contains($0) }
        guard !refused.isEmpty else { return }
        if outcome.deniedByPermissions {
            explainTrashPermission(for: refused)
        } else if let message = outcome.message {
            let alert = NSAlert()
            alert.messageText = "Couldn’t move \(Self.describe(refused)) to the Trash"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private struct RecycleOutcome: Sendable {
        var trashed: Set<URL>
        var deniedByPermissions: Bool
        var message: String?
    }

    /// The completion-handler form rather than `async throws`: that one throws away the files that
    /// did reach the Trash whenever any file in the batch fails.
    private static func recycle(_ urls: [URL]) async -> RecycleOutcome {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                continuation.resume(returning: RecycleOutcome(
                    trashed: Set(moved.keys),
                    deniedByPermissions: error.map(isPermissionError) ?? false,
                    message: error?.localizedDescription))
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

    /// macOS refuses to trash files in protected places until FinderPlus has Full Disk Access; files
    /// owned by the system need Finder, which can ask for an administrator password.
    private func explainTrashPermission(for urls: [URL]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "FinderPlus needs Full Disk Access to delete \(Self.describe(urls))"
        alert.informativeText = """
            macOS blocked the move to the Trash. Turn on FinderPlus in System Settings › Privacy & \
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
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        default:
            break
        }
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccessAtLaunch() {
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
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, _ defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
