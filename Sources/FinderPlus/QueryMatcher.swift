import Foundation

enum QueryError: LocalizedError {
    case empty
    case onlyExclusions
    case invalidPattern(String)

    var errorDescription: String? {
        switch self {
        case .empty: "Type something to search for."
        case .onlyExclusions: "Add a word to look for — words starting with - or NOT only leave things out."
        case .invalidPattern(let pattern): "“\(pattern)” is not a valid pattern."
        }
    }
}

/// An excerpt of file contents and the matched span inside it, in UTF-16 units.
struct Snippet: Hashable, Sendable {
    let text: String
    let match: NSRange
}

/// A compiled query. Built once per search and shared by every worker thread.
///
/// A query is a list of clauses and matches when any clause does; a clause matches when all of its
/// required patterns are found and none of its excluded ones. Every operator reduces to that:
/// All Words is one clause, Any Word is one clause per word, Boolean splits clauses on OR.
///
/// `@unchecked` because `NSRegularExpression` is immutable and documented thread-safe, but not
/// annotated `Sendable` in every SDK.
struct QueryMatcher: @unchecked Sendable {
    struct Term: Equatable {
        var text: String
        var excluded: Bool
        var quoted = false
    }

    private enum Pattern {
        case regex(NSRegularExpression)
        case fuzzy(FuzzyPattern)

        func find(in text: String) -> NSRange? {
            switch self {
            case .regex(let regex):
                let range = regex.rangeOfFirstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                return range.location == NSNotFound ? nil : range
            case .fuzzy(let pattern):
                return pattern.find(in: text)
            }
        }
    }

    private struct Clause {
        var required: [Pattern]
        var excluded: [Pattern]
    }

    private let clauses: [Clause]
    private let foldsDiacritics: Bool

    /// `anchorsWildcards`: a wildcard pattern such as `*.pdf` means a whole name, but a fragment of
    /// file contents or a comment. Terms without `*` or `?` are substring searches either way.
    init(query: String, options: SearchOptions, anchorsWildcards: Bool = true) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QueryError.empty }
        foldsDiacritics = options.ignoreDiacritics
        let source = options.ignoreDiacritics ? Self.fold(trimmed) : trimmed
        let regexOptions: NSRegularExpression.Options = options.ignoreCase ? [.caseInsensitive] : []

        func regex(_ pattern: String, bounded: Bool = options.wholeWords) throws -> Pattern {
            let full = bounded ? "\\b(?:\(pattern))\\b" : pattern
            do {
                return .regex(try NSRegularExpression(pattern: full, options: regexOptions))
            } catch {
                throw QueryError.invalidPattern(pattern)
            }
        }
        func literal(_ text: String) throws -> Pattern {
            if options.usesFuzzy { return .fuzzy(FuzzyPattern(text, ignoreCase: options.ignoreCase)) }
            return try regex(NSRegularExpression.escapedPattern(for: text))
        }
        func wildcard(_ text: String) throws -> Pattern {
            let anchored = anchorsWildcards && (text.contains("*") || text.contains("?"))
            return try regex(Self.wildcardPattern(text, anchored: anchored), bounded: options.wholeWords && !anchored)
        }

        var clauses: [Clause]
        switch options.mode {
        case .allWords, .anyWord:
            let terms = Self.tokenize(source)
            let positive = try terms.filter { !$0.excluded }.map { try literal($0.text) }
            let excluded = try terms.filter(\.excluded).map { try literal($0.text) }
            clauses = options.mode == .allWords
                ? [Clause(required: positive, excluded: excluded)]
                : positive.map { Clause(required: [$0], excluded: excluded) }
        case .phrase:
            clauses = [Clause(required: [try literal(source)], excluded: [])]
        case .wildcards:
            clauses = [Clause(required: [try wildcard(source)], excluded: [])]
        case .boolean:
            clauses = try Self.booleanGroups(source).map { group in
                Clause(
                    required: try group.filter { !$0.excluded }.map { try wildcard($0.text) },
                    excluded: try group.filter(\.excluded).map { try wildcard($0.text) })
            }
        case .regex:
            clauses = [Clause(required: [try regex(source)], excluded: [])]
        }
        // A clause of exclusions alone would match nearly every file on the disk.
        let hadExclusions = clauses.contains { !$0.excluded.isEmpty }
        clauses.removeAll { $0.required.isEmpty }
        guard !clauses.isEmpty else { throw hadExclusions ? QueryError.onlyExclusions : QueryError.empty }
        self.clauses = clauses
    }

    /// Whether a name, tag or comment matches.
    func matches(_ text: String) -> Bool {
        firstMatch(in: subject(for: text)) != nil
    }

    /// A one-line excerpt around the first match, or nil when the text does not match.
    func snippet(in text: String, context: Int = 40) -> Snippet? {
        let folded = subject(for: text)
        guard var range = firstMatch(in: folded) else { return nil }
        let subject = folded as NSString
        // Never trust a range past the end: an excerpt must not be able to crash a search.
        range.location = min(range.location, subject.length)
        range.length = min(range.length, subject.length - range.location)
        // Folding usually preserves UTF-16 length; when it does, excerpt the original so the
        // snippet keeps its accents.
        let original = text as NSString
        let source = original.length == subject.length ? original : subject
        let start = max(0, range.location - context)
        let end = min(source.length, range.location + range.length + context * 2)
        let window = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: end - start))

        // Collapsed in three pieces so the match's position survives the whitespace squeeze.
        func piece(_ from: Int, _ to: Int) -> String {
            source.substring(with: NSRange(location: from, length: to - from))
                .replacing(/\s+/, with: " ")
        }
        let before = String(piece(window.location, range.location).drop(while: \.isWhitespace))
        let match = piece(range.location, NSMaxRange(range))
        let after = String(piece(NSMaxRange(range), NSMaxRange(window)).reversed().drop(while: \.isWhitespace).reversed())
        let lead = (window.location > 0 ? "…" : "") + before
        let tail = NSMaxRange(window) < source.length ? "…" : ""
        return Snippet(
            text: lead + match + after + tail,
            match: NSRange(location: lead.utf16.count, length: match.utf16.count))
    }

    private func subject(for text: String) -> String {
        foldsDiacritics ? Self.fold(text) : text
    }

    private func firstMatch(in text: String) -> NSRange? {
        clauseLoop: for clause in clauses {
            if clause.excluded.contains(where: { $0.find(in: text) != nil }) { continue }
            var first: NSRange?
            for pattern in clause.required {
                guard let range = pattern.find(in: text) else { continue clauseLoop }
                first = first ?? range
            }
            return first
        }
        return nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Splits on whitespace, keeps "quoted phrases" together, and marks `-word` as excluded.
    static func tokenize(_ query: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var inQuotes = false
        var isExcluded = false
        var wasQuoted = false

        func flush() {
            if !current.isEmpty { terms.append(Term(text: current, excluded: isExcluded, quoted: wasQuoted)) }
            current = ""
            isExcluded = false
            wasQuoted = false
        }

        for character in query {
            if character == "\"" {
                if inQuotes || !current.isEmpty { flush() }
                inQuotes.toggle()
                wasQuoted = inQuotes
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else if character == "-" && current.isEmpty && !inQuotes && !isExcluded {
                isExcluded = true
            } else {
                current.append(character)
            }
        }
        flush()
        return terms
    }

    /// `a AND b OR c NOT d` → `[[a, b], [c, -d]]`: OR separates groups, AND binds tighter, and NOT
    /// (or `!`, or a leading `-`) excludes the term after it. No parentheses — EasyFind has none
    /// either, and a flat OR-of-ANDs covers what people type into a search field.
    static func booleanGroups(_ query: String) -> [[Term]] {
        var groups: [[Term]] = [[]]
        var negateNext = false
        for var term in tokenize(query) {
            if !term.quoted {
                switch term.text {
                case "AND", "&", "&&":
                    continue
                case "OR", "|", "||":
                    groups.append([])
                    continue
                case "NOT", "!":
                    negateNext = true
                    continue
                default:
                    if term.text.hasPrefix("!"), term.text.count > 1 {
                        term.text.removeFirst()
                        term.excluded = true
                    }
                }
            }
            if negateNext {
                term.excluded = true
                negateNext = false
            }
            groups[groups.count - 1].append(term)
        }
        return groups.filter { !$0.isEmpty }
    }

    static func wildcardPattern(_ text: String, anchored: Bool) -> String {
        // Unanchored, a leading or trailing `*` changes nothing about whether text matches — but
        // `.*x` makes the regex engine rescan every line from each position, which on a single
        // long line (minified JSON) is quadratic: 100,000 characters measured at 48 seconds.
        var text = Substring(text)
        if !anchored {
            let trimmed = text.drop { $0 == "*" }.reversed().drop { $0 == "*" }.reversed()
            if !trimmed.isEmpty { text = Substring(String(trimmed)) }
        }
        var pattern = ""
        for character in text {
            switch character {
            case "*": pattern += ".*"
            case "?": pattern += "."
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return anchored ? "^\(pattern)$" : pattern
    }
}

/// Approximate substring search (Sellers' algorithm): finds the needle anywhere in the text with up
/// to `maxEdits` insertions, deletions, substitutions or swapped neighbours — a swap counts once,
/// since "invocie" is the commonest typo there is. O(text × needle), which is nothing for a file
/// name and noticeable across large files — hence it only runs when Fuzzy is on.
struct FuzzyPattern: Sendable {
    let needle: [UInt16]
    let maxEdits: Int
    let ignoreCase: Bool

    init(_ needle: String, ignoreCase: Bool) {
        self.ignoreCase = ignoreCase
        self.needle = ignoreCase ? Self.caseFolded(Array(needle.utf16)) : Array(needle.utf16)
        // Short words tolerate nothing, or every three-letter word would match half the disk.
        maxEdits = switch self.needle.count {
        case ..<4: 0
        case ..<8: 1
        default: 2
        }
    }

    /// Lowercases one UTF-16 unit at a time, leaving any unit whose lowercase form is longer as it
    /// is. `String.lowercased()` would turn "İ" into two units, shifting every offset after it and
    /// putting the highlight — and the snippet range — past the end of the text.
    static func caseFolded(_ units: [UInt16]) -> [UInt16] {
        units.map { unit in
            if unit < 0x80 {
                return (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
            }
            guard let scalar = Unicode.Scalar(unit) else { return unit }
            let lower = String(scalar).lowercased().utf16
            return lower.count == 1 ? lower.first! : unit
        }
    }

    func find(in text: String) -> NSRange? {
        let haystack = ignoreCase ? Self.caseFolded(Array(text.utf16)) : Array(text.utf16)
        let m = needle.count
        guard m > 0 else { return nil }
        var best: (end: Int, cost: Int)?
        var beforePrevious = Array(0...m)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for (j, unit) in haystack.enumerated() {
            current[0] = 0
            for i in 1...m {
                let substitution = previous[i - 1] + (needle[i - 1] == unit ? 0 : 1)
                current[i] = min(substitution, previous[i] + 1, current[i - 1] + 1)
                if i > 1, j > 0, needle[i - 1] == haystack[j - 1], needle[i - 2] == unit {
                    current[i] = min(current[i], beforePrevious[i - 2] + 1)
                }
            }
            // Keep going while the match keeps getting closer, so "invoice" ends on its "e" rather
            // than one letter early at "invoic", which already fits within one edit.
            if current[m] <= maxEdits, current[m] < (best?.cost ?? .max) {
                best = (j, current[m])
            } else if best != nil {
                break
            }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        guard let best else { return nil }
        let start = max(0, best.end - m + 1)
        return NSRange(location: start, length: best.end - start + 1)
    }
}
