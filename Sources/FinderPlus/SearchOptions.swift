import Foundation

/// Which items are candidates — EasyFind's "Search for" radio group.
enum SearchKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case filesAndFolders, files, folders

    var id: Self { self }

    var title: String {
        switch self {
        case .filesAndFolders: "Files & Folders"
        case .files: "Only Files"
        case .folders: "Only Folders"
        }
    }
}

/// How the query text is interpreted — EasyFind's "Operator".
enum MatchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case allWords, anyWord, phrase, wildcards, boolean, regex

    var id: Self { self }

    var title: String {
        switch self {
        case .allWords: "All Words"
        case .anyWord: "Any Word"
        case .phrase: "Phrase"
        case .wildcards: "Wildcards"
        case .boolean: "Boolean + Wildcards"
        case .regex: "Regular Expressions"
        }
    }

    var hint: String {
        switch self {
        case .allWords: "Every word must match. \"Quote phrases\", -exclude words."
        case .anyWord: "At least one word must match. -exclude words."
        case .phrase: "The text must appear exactly as typed."
        case .wildcards: "* matches anything, ? matches one character — e.g. *.pdf"
        case .boolean: "AND, OR, NOT (or &, |, !) between wildcard terms — e.g. *.pdf OR *.doc NOT draft"
        case .regex: "ICU regular expression syntax."
        }
    }

    /// Fuzzy matching tolerates typos in literal words; it has no meaning for patterns.
    var supportsFuzzy: Bool {
        self == .allWords || self == .anyWord || self == .phrase
    }
}

/// "Modified within" — EasyFind-style date narrowing, measured back from when the search starts.
enum DateFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any, today, week, month, year

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Any Time"
        case .today: "Today"
        case .week: "Past 7 Days"
        case .month: "Past 30 Days"
        case .year: "Past Year"
        }
    }

    func cutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: nil
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .day, value: -30, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any, under1MB, over1MB, over100MB, over1GB

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Any Size"
        case .under1MB: "Under 1 MB"
        case .over1MB: "Over 1 MB"
        case .over100MB: "Over 100 MB"
        case .over1GB: "Over 1 GB"
        }
    }

    /// `size` is -1 for folders and packages, which only "Any Size" accepts: their size is unknown.
    func accepts(_ size: Int64) -> Bool {
        let megabyte: Int64 = 1_000_000
        switch self {
        case .any: return true
        case .under1MB: return size >= 0 && size < megabyte
        // At least, so Under and Over 1 MB between them take every file: exactly 1 MB fell in neither.
        case .over1MB: return size >= megabyte
        case .over100MB: return size > 100 * megabyte
        case .over1GB: return size > 1_000 * megabyte
        }
    }
}

/// Kinds of file that can be left out of results.
enum KindGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case images, video, audio, archives

    var id: Self { self }

    var title: String {
        switch self {
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archives: "Archives"
        }
    }
}

struct SearchOptions: Equatable, Codable, Sendable {
    var kind: SearchKind = .filesAndFolders
    var searchNames = true
    var searchContents = false
    var searchTags = false
    var searchComments = false
    /// Camera and lens, date taken, music tags, owner and permissions.
    var searchMetadata = false
    /// Read text out of images and scanned PDFs during a content search (slow; off by default).
    var recognizeText = false

    var mode: MatchMode = .allWords

    var ignoreCase = true
    var ignoreDiacritics = true
    var fuzzy = false
    var wholeWords = false

    var includePackageContents = false
    var includeHidden = false
    var excludeSystemFolders = true
    var includeApplications = true
    /// List the files inside zip archives, as if they were folders.
    var includeArchiveContents = false

    var modified: DateFilter = .any
    var size: SizeFilter = .any
    var excludedKinds: Set<KindGroup> = []

    var searchesAnyField: Bool { searchNames || searchContents || searchTags || searchComments || searchMetadata }
    /// Whether matches carry a snippet worth a Match column: text found inside or about the file.
    var readsInsideFiles: Bool { searchContents || searchMetadata }
    var usesFuzzy: Bool { fuzzy && mode.supportsFuzzy }

    var prompt: String {
        let fields = [
            searchNames ? "names" : nil,
            searchContents ? "contents" : nil,
            searchTags ? "tags" : nil,
            searchComments ? "comments" : nil,
            searchMetadata ? "metadata" : nil,
        ].compactMap { $0 }
        guard let last = fields.last else { return "Choose what to search in the options panel" }
        let list = fields.count == 1 ? last : fields.dropLast().joined(separator: ", ") + " and " + last
        return "Search \(list)"
    }
}

extension SearchOptions {
    /// Every key is optional, so options saved before a setting existed still load — the synthesized
    /// decoder would throw on the missing key and silently reset everything to the defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SearchOptions()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        kind = value(.kind, defaults.kind)
        searchNames = value(.searchNames, defaults.searchNames)
        searchContents = value(.searchContents, defaults.searchContents)
        searchTags = value(.searchTags, defaults.searchTags)
        searchComments = value(.searchComments, defaults.searchComments)
        searchMetadata = value(.searchMetadata, defaults.searchMetadata)
        recognizeText = value(.recognizeText, defaults.recognizeText)
        mode = value(.mode, defaults.mode)
        ignoreCase = value(.ignoreCase, defaults.ignoreCase)
        ignoreDiacritics = value(.ignoreDiacritics, defaults.ignoreDiacritics)
        fuzzy = value(.fuzzy, defaults.fuzzy)
        wholeWords = value(.wholeWords, defaults.wholeWords)
        includePackageContents = value(.includePackageContents, defaults.includePackageContents)
        includeHidden = value(.includeHidden, defaults.includeHidden)
        excludeSystemFolders = value(.excludeSystemFolders, defaults.excludeSystemFolders)
        includeApplications = value(.includeApplications, defaults.includeApplications)
        includeArchiveContents = value(.includeArchiveContents, defaults.includeArchiveContents)
        modified = value(.modified, defaults.modified)
        size = value(.size, defaults.size)
        excludedKinds = value(.excludedKinds, defaults.excludedKinds)
    }
}

/// App-wide preferences, edited in the Settings window.
struct AppSettings: Equatable, Codable, Sendable {
    enum DoubleClick: String, CaseIterable, Identifiable, Codable, Sendable {
        case open, reveal, quickLook

        var id: Self { self }

        var title: String {
            switch self {
            case .open: "Opens the item"
            case .reveal: "Shows it in Finder"
            case .quickLook: "Previews it with Quick Look"
            }
        }
    }

    var doubleClick: DoubleClick = .open
    var confirmTrash = true
    var rememberRecents = true
    var showFullPaths = false
    var maxContentMegabytes = 50
    /// 0 means no limit.
    var maxResults = 0
    var skippedFolderNames: [String] = []

    var limits: SearchLimits {
        SearchLimits(
            maxContentBytes: maxContentMegabytes * 1024 * 1024,
            maxResults: maxResults,
            skippedFolderNames: Set(skippedFolderNames))
    }
}

extension AppSettings {
    /// Every key is optional, for the same reason as `SearchOptions`: settings added later must not
    /// reset the ones already saved.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        doubleClick = value(.doubleClick, defaults.doubleClick)
        confirmTrash = value(.confirmTrash, defaults.confirmTrash)
        rememberRecents = value(.rememberRecents, defaults.rememberRecents)
        showFullPaths = value(.showFullPaths, defaults.showFullPaths)
        maxContentMegabytes = value(.maxContentMegabytes, defaults.maxContentMegabytes)
        maxResults = value(.maxResults, defaults.maxResults)
        skippedFolderNames = value(.skippedFolderNames, defaults.skippedFolderNames)
    }
}
