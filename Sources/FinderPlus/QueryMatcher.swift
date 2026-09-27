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
        /// An unanchored wildcard with a `*` between pieces, such as `a*z`.
        case pieces([NSRegularExpression])
        case fuzzy(FuzzyPattern)

        func find(in text: String) -> NSRange? {
            switch self {
            case .regex(let regex):
                let range = regex.rangeOfFirstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                return range.location == NSNotFound ? nil : range
            case .pieces(let pieces):
                return Self.find(pieces, in: text, from: 0)
            case .fuzzy(let pattern):
                return pattern.find(in: text)
            }
        }

        /// Each piece after the one before, all on one line — what `a.*z` means, since `.` stops at
        /// a line break. `.*` itself rescans the rest of the line from every start, which on one
        /// long line (minified JSON) is quadratic; this reads each line once per piece. The pieces
        /// are fixed-length, so the leftmost match of each is also the earliest to end, and giving
        /// up on a line at the first missing piece loses nothing.
        static func find(_ pieces: [NSRegularExpression], in text: String, from start: Int) -> NSRange? {
            let string = text as NSString
            let length = string.length
            // Transparent bounds, so Whole Words' lookarounds see past the end of the search range.
            func search(_ piece: NSRegularExpression, _ from: Int, _ to: Int) -> NSRange? {
                let range = piece.rangeOfFirstMatch(
                    in: text, options: .withTransparentBounds, range: NSRange(location: from, length: to - from))
                return range.location == NSNotFound ? nil : range
            }
            var lineStart = start
            while lineStart < length, let first = search(pieces[0], lineStart, length) {
                let rest = NSRange(location: NSMaxRange(first), length: length - NSMaxRange(first))
                let newline = string.rangeOfCharacter(from: .newlines, range: rest).location
                let lineEnd = newline == NSNotFound ? length : newline
                var end = NSMaxRange(first)
                var matched = true
                for piece in pieces.dropFirst() {
                    guard let next = search(piece, end, lineEnd) else { matched = false; break }
                    end = NSMaxRange(next)
                }
                if matched { return NSRange(location: first.location, length: end - first.location) }
                lineStart = lineEnd + 1
            }
            return nil
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
        // NFC, as `subject(for:)` is: NSRegularExpression compares code points, so a composed "é"
        // would never find a decomposed one (e + combining accent). Folding already strips both.
        let source = options.ignoreDiacritics ? Self.fold(trimmed) : trimmed.precomposedStringWithCanonicalMapping
        let regexOptions: NSRegularExpression.Options = options.ignoreCase ? [.caseInsensitive] : []

        func compile(_ full: String, reporting pattern: String) throws -> NSRegularExpression {
            do {
                return try NSRegularExpression(pattern: full, options: regexOptions)
            } catch {
                throw QueryError.invalidPattern(pattern)
            }
        }
        // Lookarounds rather than `\b`, which needs a word character beside it: with `\b`, "C++",
        // ".NET" and "#urgent" could never match, not even a file named exactly that.
        func regex(_ pattern: String, bounded: Bool = options.wholeWords) throws -> Pattern {
            .regex(try compile(bounded ? "(?<!\\w)(?:\(pattern))(?!\\w)" : pattern, reporting: pattern))
        }
        func exact(_ text: String) throws -> Pattern {
            try regex(NSRegularExpression.escapedPattern(for: text))
        }
        func literal(_ text: String) throws -> Pattern {
            if options.usesFuzzy {
                return .fuzzy(FuzzyPattern(text, ignoreCase: options.ignoreCase, wholeWords: options.wholeWords))
            }
            return try exact(text)
        }
        func wildcard(_ text: String) throws -> Pattern {
            let anchored = anchorsWildcards && (text.contains("*") || text.contains("?"))
            let pieces = text.split(separator: "*").map { Self.wildcardPattern(String($0), anchored: false) }
            if !anchored, pieces.count > 1 {
                let last = pieces.count - 1
                return .pieces(try pieces.enumerated().map { index, piece in
                    let before = options.wholeWords && index == 0 ? "(?<!\\w)" : ""
                    let after = options.wholeWords && index == last ? "(?!\\w)" : ""
                    return try compile(before + "(?:\(piece))" + after, reporting: text)
                })
            }
            return try regex(Self.wildcardPattern(text, anchored: anchored), bounded: options.wholeWords && !anchored)
        }

        var clauses: [Clause]
        // A clause of exclusions alone would match nearly every file on the disk. Counted from the
        // terms, because Any Word builds no clause at all when every word is excluded.
        var hadExclusions = false
        switch options.mode {
        case .allWords, .anyWord:
            let terms = Self.tokenize(source)
            hadExclusions = terms.contains(where: \.excluded)
            let positive = try terms.filter { !$0.excluded }.map { try literal($0.text) }
            // Exact, never fuzzy: `-paid` must not also leave out "said", "rapid" and "pain".
            let excluded = try terms.filter(\.excluded).map { try exact($0.text) }
            clauses = options.mode == .allWords
                ? [Clause(required: positive, excluded: excluded)]
                : positive.map { Clause(required: [$0], excluded: excluded) }
        case .phrase:
            clauses = [Clause(required: [try literal(source)], excluded: [])]
        case .wildcards:
            clauses = [Clause(required: [try wildcard(source)], excluded: [])]
        case .boolean:
            let groups = Self.booleanGroups(source)
            hadExclusions = groups.joined().contains(where: \.excluded)
            clauses = try groups.map { group in
                Clause(
                    required: try group.filter { !$0.excluded }.map { try wildcard($0.text) },
                    excluded: try group.filter(\.excluded).map { try wildcard($0.text) })
            }
        case .regex:
            clauses = [Clause(required: [try regex(source)], excluded: [])]
        }
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
        // snippet keeps its accents. NFC keeps them anyway, and can lengthen one sequence while
        // shortening another, so equal lengths would prove nothing: excerpt what was matched.
        let original = text as NSString
        let source = foldsDiacritics && original.length == subject.length ? original : subject
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

    /// Every place the query's words or patterns occur, for highlighting a whole document in the
    /// preview. Offsets are in the text as given: NFC's are mapped back, and accent folding keeps
    /// the length, which it almost always does; `limit` bounds the work on a huge file.
    func ranges(in text: String, limit: Int = 500) -> [NSRange] {
        // NFC as `matches` sees it, or a file that matched could highlight nothing. Its changes in
        // length cannot be undone by a length check (see `snippet`), hence the map.
        let composition = foldsDiacritics ? nil : Composition(text)
        let subject = composition?.subject ?? Self.fold(text)
        let whole = NSRange(location: 0, length: (subject as NSString).length)
        var found: [NSRange] = []
        for pattern in clauses.flatMap(\.required) {
            switch pattern {
            case .regex(let regex):
                regex.enumerateMatches(in: subject, range: whole) { match, _, stop in
                    if let match, match.range.length > 0 { found.append(match.range) }
                    if found.count >= limit { stop.pointee = true }
                }
            case .pieces(let pieces):
                var start = 0
                while found.count < limit, let range = Pattern.find(pieces, in: subject, from: start) {
                    found.append(range)
                    start = NSMaxRange(range)
                }
            case .fuzzy(let fuzzy):
                found += fuzzy.ranges(in: subject, limit: limit - found.count)
            }
            if found.count >= limit { break }
        }
        // The map keeps order, so sorting first is sorting the result.
        let sorted = found.sorted { $0.location < $1.location }
        return composition.map { composition in sorted.map(composition.original) } ?? sorted
    }

    /// Text in NFC, and the way back: where each sequence NFC changed sits in the text as given.
    private struct Composition {
        let subject: String
        /// The composed character sequences NFC changed, in order: UTF-16 offsets in `subject`
        /// and in the original text.
        private var changed: [(subject: Range<Int>, original: Range<Int>)] = []

        init(_ text: String) {
            let composed = text.precomposedStringWithCanonicalMapping
            // Code units, not `==`: String equality is canonical equivalence, true either way.
            guard !composed.utf16.elementsEqual(text.utf16) else {
                subject = text
                return
            }
            // Composed sequence by sequence, so every change stays inside one sequence and the map
            // is exact by construction. Two ASCII units in a row never compose: skipped cheaply.
            let original = text as NSString
            let units = Array(text.utf16)
            var built = ""
            var unchangedFrom = 0
            var location = 0
            var delta = 0
            while location < units.count {
                if units[location] < 0x80, location + 1 == units.count || units[location + 1] < 0x80 {
                    location += 1
                    continue
                }
                let range = original.rangeOfComposedCharacterSequence(at: location)
                let piece = original.substring(with: range)
                let normalized = piece.precomposedStringWithCanonicalMapping
                if !normalized.utf16.elementsEqual(piece.utf16) {
                    built += original.substring(
                        with: NSRange(location: unchangedFrom, length: range.location - unchangedFrom))
                    built += normalized
                    let start = range.location + delta
                    let length = normalized.utf16.count
                    changed.append((start..<start + length, range.location..<NSMaxRange(range)))
                    delta += length - range.length
                    unchangedFrom = NSMaxRange(range)
                }
                location = NSMaxRange(range)
            }
            subject = built + original.substring(from: unchangedFrom)
        }

        /// A range in `subject` as one in the original, widened to whole sequences rather than
        /// splitting one NFC changed.
        func original(_ range: NSRange) -> NSRange {
            guard !changed.isEmpty else { return range }
            let start = offset(range.location, roundingUp: false)
            let end = offset(NSMaxRange(range), roundingUp: true)
            return NSRange(location: start, length: end - start)
        }

        private func offset(_ location: Int, roundingUp: Bool) -> Int {
            // The last changed sequence starting at or before `location`.
            var low = 0
            var high = changed.count
            while low < high {
                let middle = (low + high) / 2
                if changed[middle].subject.lowerBound <= location { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { return location }
            let (subject, original) = changed[low - 1]
            if location == subject.lowerBound { return original.lowerBound }
            if location < subject.upperBound { return roundingUp ? original.upperBound : original.lowerBound }
            return location + original.upperBound - subject.upperBound
        }
    }

    private func subject(for text: String) -> String {
        foldsDiacritics ? Self.fold(text) : text.precomposedStringWithCanonicalMapping
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
    let wholeWords: Bool

    init(_ needle: String, ignoreCase: Bool, wholeWords: Bool) {
        self.ignoreCase = ignoreCase
        self.wholeWords = wholeWords
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
        ranges(in: text, limit: 1).first
    }

    /// Up to `limit` matches that do not overlap, leftmost first.
    func ranges(in text: String, limit: Int) -> [NSRange] {
        let haystack = ignoreCase ? Self.caseFolded(Array(text.utf16)) : Array(text.utf16)
        let m = needle.count
        guard m > 0, limit > 0 else { return [] }
        var found: [NSRange] = []
        var best: (start: Int, end: Int, cost: Int)?
        // Past the last match's end, so the highlights never overlap.
        var earliestStart = 0
        var beforePrevious = Array(0...m)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        // Where the cheapest alignment ending in each cell began, so a highlight covers what
        // matched: counting the needle's length back from the end lands wrong after an insertion,
        // a deletion or a character that takes two UTF-16 units.
        var beforePreviousStart = [Int](repeating: 0, count: m + 1)
        var previousStart = [Int](repeating: 0, count: m + 1)
        var currentStart = [Int](repeating: 0, count: m + 1)

        func isEligible(start: Int, end: Int, cost: Int) -> Bool {
            cost <= maxEdits && start >= earliestStart && start <= end
                && (!wholeWords || Self.isBounded(haystack, start: start, end: end))
        }
        func range(of hit: (start: Int, end: Int, cost: Int)) -> NSRange {
            (text as NSString).rangeOfComposedCharacterSequences(
                for: NSRange(location: hit.start, length: hit.end - hit.start + 1))
        }

        for (j, unit) in haystack.enumerated() {
            current[0] = 0
            currentStart[0] = j + 1
            for i in 1...m {
                var cost = previous[i - 1] + (needle[i - 1] == unit ? 0 : 1)
                var start = previousStart[i - 1]
                // Ties go to the later start: the tightest span that matches is the one to show.
                if previous[i] + 1 < cost || (previous[i] + 1 == cost && previousStart[i] > start) {
                    (cost, start) = (previous[i] + 1, previousStart[i])
                }
                if current[i - 1] + 1 < cost || (current[i - 1] + 1 == cost && currentStart[i - 1] > start) {
                    (cost, start) = (current[i - 1] + 1, currentStart[i - 1])
                }
                if i > 1, j > 0, needle[i - 1] == haystack[j - 1], needle[i - 2] == unit,
                   beforePrevious[i - 2] + 1 < cost
                    || (beforePrevious[i - 2] + 1 == cost && beforePreviousStart[i - 2] > start)
                {
                    (cost, start) = (beforePrevious[i - 2] + 1, beforePreviousStart[i - 2])
                }
                current[i] = cost
                currentStart[i] = start
            }
            // Keep going while the match keeps getting closer, so "invoice" ends on its "e" rather
            // than one letter early at "invoic", which already fits within one edit.
            let (cost, start) = (current[m], currentStart[m])
            if let hit = best, !(cost < hit.cost && isEligible(start: start, end: j, cost: cost)) {
                found.append(range(of: hit))
                if found.count >= limit { return found }
                earliestStart = hit.end + 1
                best = nil
            }
            if cost < (best?.cost ?? .max), isEligible(start: start, end: j, cost: cost) {
                best = (start, j, cost)
            }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
            (beforePreviousStart, previousStart, currentStart) = (previousStart, currentStart, beforePreviousStart)
        }
        if let best { found.append(range(of: best)) }
        return found
    }

    /// Whole Words for a fuzzy match: no word character on either side, as the regex path's
    /// `(?<!\w)` and `(?!\w)` require — otherwise "cat" is found inside "concatenate".
    static func isBounded(_ units: [UInt16], start: Int, end: Int) -> Bool {
        let before = String(decoding: units[max(0, start - 2)..<start], as: UTF16.self).unicodeScalars.last
        let after = String(decoding: units[(end + 1)..<min(units.count, end + 3)], as: UTF16.self)
            .unicodeScalars.first
        return !(before.map(isWordCharacter) ?? false) && !(after.map(isWordCharacter) ?? false)
    }

    /// ICU's `\w`: letters, marks, decimal digits, connector punctuation and the two joiners.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .decimalNumber, .connectorPunctuation, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return properties.isAlphabetic || scalar == "\u{200C}" || scalar == "\u{200D}"
        }
    }
}
