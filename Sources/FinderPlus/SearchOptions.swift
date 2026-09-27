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

struct SearchOptions: Equatable, Codable, Sendable {
    var kind: SearchKind = .filesAndFolders
    var searchNames = true
    var searchContents = false
    var searchTags = false
    var searchComments = false

    var mode: MatchMode = .allWords

    var ignoreCase = true
    var ignoreDiacritics = true
    var fuzzy = false
    var wholeWords = false

    var includePackageContents = false
    var includeHidden = false
    var excludeSystemFolders = true
    var includeApplications = true

    var searchesAnyField: Bool { searchNames || searchContents || searchTags || searchComments }
    var usesFuzzy: Bool { fuzzy && mode.supportsFuzzy }

    var prompt: String {
        let fields = [
            searchNames ? "names" : nil,
            searchContents ? "contents" : nil,
            searchTags ? "tags" : nil,
            searchComments ? "comments" : nil,
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
        mode = value(.mode, defaults.mode)
        ignoreCase = value(.ignoreCase, defaults.ignoreCase)
        ignoreDiacritics = value(.ignoreDiacritics, defaults.ignoreDiacritics)
        fuzzy = value(.fuzzy, defaults.fuzzy)
        wholeWords = value(.wholeWords, defaults.wholeWords)
        includePackageContents = value(.includePackageContents, defaults.includePackageContents)
        includeHidden = value(.includeHidden, defaults.includeHidden)
        excludeSystemFolders = value(.excludeSystemFolders, defaults.excludeSystemFolders)
        includeApplications = value(.includeApplications, defaults.includeApplications)
    }
}
