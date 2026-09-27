import AppIntents
import AppKit
import UniformTypeIdentifiers

/// The Shortcuts and Siri actions. The first two run without a window and hand their files to the
/// next action in a shortcut; the last opens the app and searches there. None of this reaches the
/// system through the code alone: build.sh compiles it into `Metadata.appintents`, which is what
/// Shortcuts, Spotlight and Siri actually index.

struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files"
    static let description = IntentDescription(
        "Finds files and folders by name — including hidden and un-indexed ones Spotlight misses — and passes them to the next action.",
        categoryName: "Search")

    @Parameter(
        title: "Name Contains",
        description: "Words the name must contain. * and ? work as wildcards, e.g. *.pdf.")
    var query: String

    @Parameter(
        title: "Folder",
        description: "Where to search. Your home folder when left empty.",
        supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(
        title: "Search Contents",
        description: "Also read inside text, PDF and office documents.",
        default: false)
    var searchContents: Bool

    @Parameter(title: "Include Hidden Files", default: false)
    var includeHidden: Bool

    @Parameter(title: "Stop After", description: "The most files to return.", default: 100, inclusiveRange: (1, 10_000))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find files matching \(\.$query) in \(\.$folder)") {
            \.$searchContents
            \.$includeHidden
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var options = SearchOptions()
        options.searchContents = searchContents
        options.includeHidden = includeHidden
        // A query with a wildcard in it means the pattern, not files named "*".
        if query.contains("*") || query.contains("?") { options.mode = .wildcards }
        let hits = try await IntentSearch.hits(
            query: query, root: folder?.fileURL ?? FileManager.default.homeDirectoryForCurrentUser,
            options: options, limit: limit)
        return .result(value: hits.map { IntentFile(fileURL: $0.url) })
    }
}

struct FindDuplicateFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Duplicate Files"
    static let description = IntentDescription(
        "Compares every file in a folder by contents and returns the extra copies, keeping the oldest of each set — ready for a Move to Trash action.",
        categoryName: "Search")

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile

    @Parameter(title: "Include Hidden Files", default: false)
    var includeHidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find duplicate files in \(\.$folder)") {
            \.$includeHidden
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let root = folder.fileURL else {
            throw IntentMessage("That folder isn’t available.")
        }
        var options = SearchOptions()
        options.kind = .files
        options.mode = .wildcards
        options.includeHidden = includeHidden
        let hits = try await IntentSearch.hits(query: "*", root: root, options: options, limit: 0)
        let candidates = hits.filter { !$0.isFolder && !$0.isArchiveEntry && $0.size > 0 }
            .map { DuplicateFinder.Candidate(id: $0.id, url: $0.url, size: $0.size) }
        let sets = await Task.detached { DuplicateFinder.sets(in: candidates) }.value
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })
        var extras: [URL] = []
        for set in sets {
            let files = set.compactMap { byID[$0] }
                .sorted { ($0.modified, $0.url.path) < ($1.modified, $1.url.path) }
            extras += files.dropFirst().map(\.url)
        }
        return .result(value: extras.map { IntentFile(fileURL: $0) })
    }
}

struct SearchInFinderPlusIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in FinderPlus"
    static let description = IntentDescription(
        "Opens FinderPlus and runs the search there, with the full options and results window.",
        categoryName: "Search")
    static let openAppWhenRun = true

    @Parameter(title: "Search For")
    var query: String

    @Parameter(
        title: "Folder",
        description: "Where to search. The window’s current location when left empty.",
        supportedContentTypes: [.folder])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query) in FinderPlus") {
            \.$folder
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        (NSApp.delegate as? AppDelegate)?.searchFromIntent(query: query, folder: folder?.fileURL)
        return .result()
    }
}

/// What Siri answers to. The phrases have to carry the app's name, so the system can tell them
/// from every other app's.
struct FinderPlusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchInFinderPlusIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Find files with \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass")
    }
}

/// The engine, run headless for the background intents: same walk, no window.
enum IntentSearch {
    static func hits(query: String, root: URL, options: SearchOptions, limit: Int) async throws -> [FileHit] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw IntentMessage("“\(root.lastPathComponent)” isn’t a folder that can be searched.") }
        let request = try SearchRequest(
            roots: [root], query: query, options: options, limits: SearchLimits(maxResults: limit))
        var collected: [FileHit] = []
        for await event in SearchEngine.run(request) {
            if case .hits(let hits) = event { collected += hits }
        }
        return limit > 0 ? Array(collected.prefix(limit)) : collected
    }
}

struct IntentMessage: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
