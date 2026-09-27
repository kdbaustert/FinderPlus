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
    case finderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noRemovableVolumes:
            "No removable volumes are connected."
        case .finderUnavailable(let reason):
            "Couldn’t read the front Finder window (\(reason)). Allow FinderPlus to control Finder in "
                + "System Settings › Privacy & Security › Automation."
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
    }

    var query = ""
    var options: SearchOptions { didSet { save(options, Key.options) } }
    var customLocations: [SearchLocation] { didSet { save(customLocations, Key.folders) } }
    var locationID: String { didSet { save(locationID, Key.location) } }
    private(set) var recentQueries: [String] { didSet { save(recentQueries, Key.recents) } }

    var results: [FileHit] = []
    var selection: Set<URL> = []
    var sortOrder = [KeyPathComparator(\FileHit.name, comparator: .localizedStandard)]
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Where and how the results on screen were searched, so the next Find can tell whether it is
    /// refining them.
    @ObservationIgnored private var lastRun: Run?
    /// IDs already in `results`, so a hit carried over from the previous run is not added twice.
    @ObservationIgnored private var knownIDs: Set<URL> = []

    private struct Run: Equatable {
        let options: SearchOptions
        let locationID: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = Self.load(SearchOptions.self, Key.options, defaults) ?? SearchOptions()
        customLocations = Self.load([SearchLocation].self, Key.folders, defaults) ?? []
        locationID = Self.load(String.self, Key.location, defaults) ?? NSHomeDirectory()
        recentQueries = Self.load([String].self, Key.recents, defaults) ?? []
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
        let request: SearchRequest
        do {
            request = try SearchRequest(roots: searchRoots(), query: query, options: options)
        } catch QueryError.empty {
            results = []
            phase = .idle
            return
        } catch {
            results = []
            phase = .failed(error.localizedDescription)
            return
        }

        remember(query)
        let run = Run(options: options, locationID: locationID)
        let refinesLast = lastRun == run
        lastRun = run
        if refinesLast && options.searchNames {
            // A new query in the same place with the same options narrows what is on screen
            // instead of blanking it while the walk starts over. What stays still matches by name,
            // so the new walk would report it anyway.
            results.removeAll { !request.nameMatcher.matches($0.name) }
        } else {
            results = []
        }
        knownIDs = Set(results.map(\.id))
        selection.formIntersection(knownIDs)
        scanned = 0
        unreadable = 0
        currentPath = ""
        searchedContents = options.searchContents
        phase = .searching

        let started = ContinuousClock.now
        searchTask = Task { [weak self] in
            for await event in SearchEngine.run(request) {
                self?.apply(event)
            }
            guard !Task.isCancelled, let self else { return }
            phase = .finished(started.duration(to: .now))
        }
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

    /// Merges a batch into the already-sorted results, so rows land in place as they are found
    /// rather than piling up at the bottom and jumping when the search ends.
    private func insertSorted(_ hits: [FileHit]) {
        let batch = hits.filter { knownIDs.insert($0.id).inserted }.sorted(by: precedes)
        guard !batch.isEmpty else { return }
        var merged: [FileHit] = []
        merged.reserveCapacity(results.count + batch.count)
        var i = 0, j = 0
        while i < results.count, j < batch.count {
            if precedes(batch[j], results[i]) {
                merged.append(batch[j])
                j += 1
            } else {
                merged.append(results[i])
                i += 1
            }
        }
        merged += results[i...]
        merged += batch[j...]
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
        }
    }

    func searchRoots() throws -> [URL] {
        switch location {
        case .allVolumes:
            return Self.volumes { _ in true }
        case .localVolumes:
            return Self.volumes { $0.volumeIsLocal ?? true }
        case .removableVolumes:
            // USB drives usually report ejectable rather than removable; either counts.
            let roots = Self.volumes { ($0.volumeIsRemovable ?? false) || ($0.volumeIsEjectable ?? false) }
            guard !roots.isEmpty else { throw LocationError.noRemovableVolumes }
            return roots
        case .activeFinderWindow:
            return [try Self.frontFinderFolder()]
        case .folder(let path):
            return [URL(filePath: path, directoryHint: .isDirectory)]
        }
    }

    /// `/` is among the mounted volumes; the walk skips `/Volumes`, so each other volume is walked
    /// once, from its own root.
    private static func volumes(where include: (URLResourceValues) -> Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.filter { include((try? $0.resourceValues(forKeys: keys)) ?? URLResourceValues()) }
    }

    /// Resolved when the search starts, like EasyFind. Finder with no windows open means the
    /// Desktop, which is what Finder itself shows then.
    private static func frontFinderFolder() throws -> URL {
        let source = """
            tell application "Finder"
                if (count of Finder windows) is 0 then return POSIX path of (desktop as alias)
                return POSIX path of (target of front Finder window as alias)
            end tell
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let path = result?.stringValue else {
            let reason = error?[NSAppleScript.errorMessage] as? String ?? "no answer"
            throw LocationError.finderUnavailable(reason)
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func remember(_ query: String) {
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

    /// Result URLs for `ids`, or for the selection, in display order.
    func targets(_ ids: Set<URL>?) -> [URL] {
        let ids = ids ?? selection
        guard !ids.isEmpty else { return [] }
        return results.lazy.map(\.url).filter(ids.contains)
    }

    func open(_ ids: Set<URL>? = nil) {
        for url in targets(ids) { NSWorkspace.shared.open(url) }
    }

    func reveal(_ ids: Set<URL>? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(targets(ids))
    }

    func copyPaths(_ ids: Set<URL>? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets(ids).map(\.path).joined(separator: "\n"), forType: .string)
    }

    func toggleQuickLook() {
        previewURL = previewURL == nil ? targets(nil).first : nil
    }

    func trash(_ ids: Set<URL>? = nil) async {
        let urls = targets(ids)
        guard !urls.isEmpty else { return }
        do {
            let trashed = Set(try await NSWorkspace.shared.recycle(urls).keys)
            results.removeAll { trashed.contains($0.url) }
            selection.subtract(trashed)
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: - Persistence

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, _ defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
