import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import os

/// Every suite is a plist in ~/Library/Preferences. `removePersistentDomain` empties it but
/// cfprefsd keeps the empty file, so the file goes too — domain first, so nothing rewrites it.
func removeSuite(named name: String) {
    UserDefaults().removePersistentDomain(forName: name)
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: plist)
}
@testable import FinderPlus

final class QueryMatcherTests: XCTestCase {
    private func matcher(
        _ query: String, anchors: Bool = true, _ configure: (inout SearchOptions) -> Void = { _ in }
    ) throws -> QueryMatcher {
        var options = SearchOptions()
        configure(&options)
        return try QueryMatcher(query: query, options: options, anchorsWildcards: anchors)
    }

    func testTokenizeQuotesAndExclusions() {
        XCTAssertEqual(QueryMatcher.tokenize(#"invoice "tax year" -draft a-b"#), [
            .init(text: "invoice", excluded: false),
            .init(text: "tax year", excluded: false, quoted: true),
            .init(text: "draft", excluded: true),
            .init(text: "a-b", excluded: false),
        ])
        XCTAssertEqual(QueryMatcher.tokenize(#"-"old copy""#), [.init(text: "old copy", excluded: true, quoted: true)])
    }

    func testAllWordsRequiresEveryTermInAnyOrder() throws {
        let m = try matcher("report 2024")
        XCTAssertTrue(m.matches("2024 Annual Report.pdf"))
        XCTAssertFalse(m.matches("Annual Report.pdf"))
    }

    func testAnyWordNeedsOneTerm() throws {
        let m = try matcher("invoice receipt -old") { $0.mode = .anyWord }
        XCTAssertTrue(m.matches("receipt-march.png"))
        XCTAssertFalse(m.matches("old receipt.png"))
        XCTAssertFalse(m.matches("notes.txt"))
    }

    func testExclusion() throws {
        let m = try matcher("report -draft")
        XCTAssertTrue(m.matches("report final.docx"))
        XCTAssertFalse(m.matches("report DRAFT.docx"))
    }

    func testCaseAndDiacritics() throws {
        XCTAssertTrue(try matcher("resume").matches("Résumé.pages"))
        XCTAssertFalse(try matcher("resume") { $0.ignoreDiacritics = false }.matches("Résumé.pages"))
        XCTAssertFalse(try matcher("Report") { $0.ignoreCase = false }.matches("report.txt"))
    }

    func testWholeWords() throws {
        let m = try matcher("cat") { $0.wholeWords = true }
        XCTAssertTrue(m.matches("my cat.jpg"))
        XCTAssertFalse(m.matches("concatenate.swift"))
    }

    func testWildcardsAnchorOnlyNamesAndOnlyWhenWildcardPresent() throws {
        let pdf = try matcher("*.pdf") { $0.mode = .wildcards }
        XCTAssertTrue(pdf.matches("Scan 01.pdf"))
        XCTAssertFalse(pdf.matches("Scan 01.pdf.zip"))
        XCTAssertTrue(try matcher("*.pdf", anchors: false) { $0.mode = .wildcards }.matches("see Scan.pdf.zip"))
        XCTAssertTrue(try matcher("IMG_????.heic") { $0.mode = .wildcards }.matches("IMG_1234.heic"))
        XCTAssertTrue(try matcher("scan") { $0.mode = .wildcards }.matches("old scan.png"))
    }

    func testBooleanGroups() {
        let groups = QueryMatcher.booleanGroups("*.pdf OR *.docx NOT draft !old")
        XCTAssertEqual(groups.map { $0.map(\.text) }, [["*.pdf"], ["*.docx", "draft", "old"]])
        XCTAssertEqual(groups[1].map(\.excluded), [false, true, true])
        XCTAssertEqual(QueryMatcher.booleanGroups(#"a AND "OR""#).map { $0.map(\.text) }, [["a", "OR"]])
    }

    func testBooleanMatching() throws {
        let m = try matcher("*.pdf OR *.docx NOT *draft*") { $0.mode = .boolean }
        XCTAssertTrue(m.matches("Invoice.pdf"))
        XCTAssertTrue(m.matches("Letter.docx"))
        XCTAssertFalse(m.matches("Letter draft.docx"))
        XCTAssertFalse(m.matches("Notes.txt"))
        XCTAssertTrue(try matcher("tax & 2024 | receipt") { $0.mode = .boolean }.matches("2024 tax.xlsx"))
        XCTAssertThrowsError(try matcher("NOT draft") { $0.mode = .boolean })
    }

    func testFuzzyToleratesTyposInLongerWords() throws {
        let m = try matcher("invoice") { $0.fuzzy = true }
        XCTAssertTrue(m.matches("Invocie March.pdf"))
        XCTAssertTrue(m.matches("invoce.pdf"))
        XCTAssertFalse(m.matches("involved.txt"))
        XCTAssertFalse(try matcher("cat") { $0.fuzzy = true }.matches("cut.txt"))
        XCTAssertFalse(try matcher("invoice") { $0.fuzzy = true; $0.mode = .regex }.matches("invoce.pdf"))
    }

    func testRegexAndInvalidPattern() throws {
        XCTAssertTrue(try matcher(#"^\d{4}-\d{2}"#) { $0.mode = .regex }.matches("2024-05 notes.md"))
        XCTAssertThrowsError(try matcher("(unclosed") { $0.mode = .regex })
        XCTAssertThrowsError(try matcher("   "))
        XCTAssertThrowsError(try matcher("-onlyexcluded"))
    }

    func testSnippetKeepsAccentsAndTrimsContext() throws {
        let text = String(repeating: "filler ", count: 30) + "the café opens at nine\n\nand closes late"
        let snippet = try XCTUnwrap(try matcher("cafe").snippet(in: text, context: 10))
        XCTAssertTrue(snippet.text.contains("café"))
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.match), "café")
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertFalse(snippet.text.contains("\n"))
    }

    // NFC changes the text's length, so the highlight has to be mapped back to the text as given.
    func testRangesAfterADecomposedAccentCoverTheMatchInTheOriginalText() throws {
        let text = "re\u{301}sume\u{301} then a cat sat"
        let expected = (text as NSString).range(of: "cat")
        XCTAssertNotEqual(expected.location, NSNotFound)
        // Both settings: folding drops the two combining accents, NFC composes them, and either
        // way the text matched is two units shorter than the text shown.
        for ignoreDiacritics in [false, true] {
            let m = try matcher("cat", anchors: false) { $0.ignoreDiacritics = ignoreDiacritics }
            let found = m.ranges(in: text)
            XCTAssertEqual(found, [expected], "ignoreDiacritics: \(ignoreDiacritics)")
            XCTAssertEqual(found.map { (text as NSString).substring(with: $0) }, ["cat"])
        }
        // A match on the accented word itself covers its combining marks too.
        let folded = try matcher("resume", anchors: false) { $0.ignoreDiacritics = true }
        XCTAssertEqual(
            folded.ranges(in: text).map { (text as NSString).substring(with: $0) }, ["re\u{301}sume\u{301}"])
    }

    // An unanchored `a*z` is the `.pieces` path: each piece after the one before, on one line.
    func testRangesOfAWholeWordWildcardStayOnOneLine() throws {
        let m = try matcher("a*z", anchors: false) {
            $0.mode = .wildcards
            $0.wholeWords = true
        }
        let text = "a to z\nazure sky\nno match here"
        let found = m.ranges(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["a to z"])
        XCTAssertEqual(m.ranges(in: "azure sky\nno match here"), [])
    }

    // ICU backtracks exponentially on patterns like (a+)+$, and `rangeOfFirstMatch` cannot be
    // interrupted — not even by Stop — so a guarded match gives up within its budget instead of
    // holding the thread for hours.
    func testARunawayRegexGivesUpInsideItsBudget() throws {
        let m = try matcher("(a+)+$") { $0.mode = .regex }
        let started = ContinuousClock.now
        XCTAssertFalse(m.matches(String(repeating: "a", count: 40) + "!"))
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertTrue(m.matches(String(repeating: "a", count: 40)), "a real match is still found")
        XCTAssertEqual(m.ranges(in: "xaaa").count, 1, "ranges stay guarded and still report matches")
    }

    // `^` and `$` used to anchor to the whole file, so `^import` missed every line but the first.
    func testRegexAnchorsMatchLines() throws {
        let m = try matcher("^import") { $0.mode = .regex }
        XCTAssertTrue(m.matches("let x = 1\nimport Foundation"))
        XCTAssertFalse(m.matches("do not import this"))
    }

    // Folding "ಬೇ" grows by a mark while a decomposed "é" shrinks by one, so the total length is
    // unchanged and the old equal-length shortcut trusted offsets that were two units off: the
    // highlight read "nvoice ".
    func testHighlightsStayPutAfterALengtheningVowelSign() throws {
        let text = "ಬೇಕು invoice cafe\u{301}"
        let m = try matcher("invoice", anchors: false)
        let expected = (text as NSString).range(of: "invoice")
        XCTAssertEqual(m.ranges(in: text), [expected])
        XCTAssertEqual(m.ranges(in: text).map { (text as NSString).substring(with: $0) }, ["invoice"])
        let snippet = try XCTUnwrap(m.snippet(in: text))
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.match), "invoice")
    }
}

extension QueryMatcherTests {
    private func regexMatcher(
        _ query: String, budget: Duration = .milliseconds(50), _ configure: (inout SearchOptions) -> Void = { _ in }
    ) throws -> QueryMatcher {
        var options = SearchOptions()
        options.mode = .regex
        configure(&options)
        return try QueryMatcher(query: query, options: options, anchorsWildcards: false, timeBudget: budget)
    }

    private var runaway: String { String(repeating: "a", count: 48) + "!" }

    // A text the pattern timed out on was a silent non-match, indistinguishable from a clean miss.
    func testTimedOutRegexIsNotAMatchAndIsCounted() throws {
        let m = try regexMatcher("(a+)+$")
        XCTAssertFalse(m.matches(runaway))
        XCTAssertEqual(m.timeouts, 1)
        XCTAssertTrue(try regexMatcher("b+$").matches("abb"))
    }

    // The budget was per text, so `(a+)+$` over ten thousand names cost hours.
    func testRunawayRegexIsGivenUpOnAfterAFewShortTexts() throws {
        let m = try regexMatcher("(a+)+$", budget: .milliseconds(100))
        let started = ContinuousClock.now
        for _ in 0..<200 { XCTAssertFalse(m.matches(runaway)) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertEqual(m.timeouts, 200)
    }

    // A fixed two seconds timed out sound patterns over a 50 MB log on a slower Mac.
    func testRegexBudgetGrowsWithTheText() {
        let guardian = QueryMatcher.RegexGuard()
        XCTAssertLessThan(guardian.budget(forLength: 100), .seconds(3))
        XCTAssertGreaterThanOrEqual(guardian.budget(forLength: 50_000_000), .seconds(10))
    }

    // Six stars on a 184-character name ran past two minutes as one anchored regex.
    func testAnchoredWildcardWithManyStarsIsLinear() throws {
        let m = try matcher("*a*b*c*d*e*f*.pdf") { $0.mode = .wildcards }
        let started = ContinuousClock.now
        XCTAssertFalse(m.matches(String(repeating: "a", count: 180) + ".txt"))
        XCTAssertFalse(m.matches(String(repeating: "abcdef", count: 30) + ".pdx"))
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(m.matches("xaxbxcxdxexfx.pdf"))
        XCTAssertTrue(m.matches("abcdef.pdf"))
        XCTAssertFalse(m.matches("abcde.pdf"))
        XCTAssertFalse(try matcher("a*b*c") { $0.mode = .wildcards }.matches("xa-b-c"), "anchored at the start")
        XCTAssertFalse(try matcher("a*b*c") { $0.mode = .wildcards }.matches("a-b-cx"), "anchored at the end")
        XCTAssertTrue(try matcher("a*b*c") { $0.mode = .wildcards }.matches("a-b-c"))
        XCTAssertTrue(try matcher("a*a*aa") { $0.mode = .wildcards }.matches("aaaa"), "a later piece is not starved by an earlier one")
    }

    // `^` and `$` matched per line, so `*.pdf` found a name whose second line ended in ".pdf".
    func testAnchoredWildcardMatchesTheWholeNameNotALine() throws {
        XCTAssertFalse(try matcher("*.pdf") { $0.mode = .wildcards }.matches("notes\nreport.pdf"))
        XCTAssertFalse(try matcher("a*b*c") { $0.mode = .wildcards }.matches("a\nb\nc"))
        XCTAssertTrue(try matcher("*.pdf") { $0.mode = .wildcards }.matches("report.pdf"))
    }

    // The edge `*` was trimmed and the rest bounded as a whole word, so `rep*` found no "report".
    func testWholeWordsKeepsAnEdgeStar() throws {
        let text = "The annual report is due on Friday"
        XCTAssertTrue(try matcher("rep*", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches(text))
        XCTAssertTrue(try matcher("*port", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches(text))
        XCTAssertTrue(try matcher("*nnual rep*", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches(text))
        XCTAssertTrue(try matcher("rep* AND fri*", anchors: false) { $0.wholeWords = true; $0.mode = .boolean }.matches(text))
        XCTAssertTrue(try matcher("*nnu*epo*", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches(text))
        // The open left edge is lazy: greedy, it ran to the last "foo" and then found no "bar".
        XCTAssertTrue(try matcher("*foo*bar*", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches("a foobarfoo b"))
        XCTAssertFalse(try matcher("rep*", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches("a prep step"))
        XCTAssertFalse(try matcher("*port", anchors: false) { $0.wholeWords = true; $0.mode = .wildcards }.matches("reports"))
    }

    // A phrase was one escaped literal, so a line break in the file split it.
    func testPhraseMatchesAcrossLineBreaks() throws {
        let text = "The annual\n  report is due"
        let phrase = try matcher("annual report", anchors: false) { $0.mode = .phrase }
        XCTAssertTrue(phrase.matches(text))
        let snippet = try XCTUnwrap(phrase.snippet(in: text))
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.match), "annual report")
        XCTAssertEqual(phrase.ranges(in: text), [NSRange(location: 4, length: 15)])
        XCTAssertTrue(try matcher("\"annual report\" due", anchors: false).matches(text))
        XCTAssertFalse(phrase.matches("The annualreport"))
    }

    // Folding rewrote the pattern itself: `[À-ÿ]` became `[A-y]`, which matches "p".
    func testRegexModeDoesNotFoldTheDiacritics() throws {
        XCTAssertFalse(try regexMatcher("[À-ÿ]").matches("pqrs"))
        XCTAssertTrue(try regexMatcher("[À-ÿ]").matches("café"))
        XCTAssertTrue(try regexMatcher("café").matches("un café noir"))
        XCTAssertTrue(try regexMatcher("\\p{Mn}").matches("x\u{301}"))
        XCTAssertTrue(try regexMatcher("CAFÉ").matches("café"), "Ignore Case still applies")
        XCTAssertEqual(try regexMatcher("caf.").ranges(in: "café au lait"), [NSRange(location: 0, length: 4)])
        // The other modes still fold.
        XCTAssertTrue(try matcher("cafe", anchors: false).matches("café"))
    }
}

final class SearchLocationTests: XCTestCase {
    func testIDsRoundTripAndOldAllVolumesIDStillResolves() {
        for location in SearchLocation.scopes + [.activeFinderWindow, .folder("/Users/someone/Work")] {
            XCTAssertEqual(SearchLocation(id: location.id), location)
        }
        XCTAssertEqual(SearchLocation(id: ""), .allVolumes)
    }

    func testDecodesFoldersSavedByEarlierBuilds() throws {
        let saved = Data(#"[{"path":"/Users/someone/Work"},{"path":""}]"#.utf8)
        let decoded = try JSONDecoder().decode([SearchLocation].self, from: saved)
        XCTAssertEqual(decoded, [.folder("/Users/someone/Work"), .allVolumes])
        let reencoded = try JSONDecoder().decode([SearchLocation].self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded, decoded)
    }

    func testDrivesIncludeTheStartupVolume() {
        XCTAssertTrue(SearchLocation.drives().contains(.folder("/")))
        XCTAssertEqual(SearchLocation.folder("/").title, FileManager.default.displayName(atPath: "/"))
    }
}

final class SearchEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Projects/Invoices"), withIntermediateDirectories: true)
        try "total due: 42 EUR".write(to: root.appending(path: "Projects/Invoices/march.txt"), atomically: true, encoding: .utf8)
        try "nothing here".write(to: root.appending(path: "Projects/readme.md"), atomically: true, encoding: .utf8)
        try "secret invoice".write(to: root.appending(path: "Projects/.hidden-invoice.txt"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0x69, 0x6E, 0x76]).write(to: root.appending(path: "Projects/blob.bin"))

        var tagged = root.appending(path: "Projects/plan.txt")
        try "q3".write(to: tagged, atomically: true, encoding: .utf8)
        var values = URLResourceValues()
        values.tagNames = ["Urgent"]
        try tagged.setResourceValues(values)

        let commented = root.appending(path: "Projects/photo.jpg")
        try Data([0xFF, 0xD8, 0x00]).write(to: commented)
        let comment = try PropertyListSerialization.data(fromPropertyList: "Holiday in Lisbon", format: .binary, options: 0)
        let status = comment.withUnsafeBytes {
            setxattr(commented.path, "com.apple.metadata:kMDItemFinderComment", $0.baseAddress, comment.count, 0, 0)
        }
        XCTAssertEqual(status, 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func search(
        _ query: String, limits: SearchLimits = SearchLimits(),
        _ configure: (inout SearchOptions) -> Void = { _ in }
    ) throws -> [FileHit] {
        var options = SearchOptions()
        configure(&options)
        let request = try SearchRequest(roots: [root], query: query, options: options, limits: limits)
        var hits: [FileHit] = []
        SearchEngine.walk(request) { event in
            if case .hits(let batch) = event { hits += batch }
        }
        return hits.sorted { $0.name < $1.name }
    }

    func testSkippedFolderNamesAreNeverSearched() throws {
        XCTAssertEqual(try search("march").map(\.name), ["march.txt"])
        XCTAssertEqual(try search("march", limits: SearchLimits(skippedFolderNames: ["INVOICES"])), [])
    }

    func testMatchLimitStopsTheWalk() throws {
        var options = SearchOptions()
        options.kind = .files
        let request = try SearchRequest(
            roots: [root], query: "t", options: options, limits: SearchLimits(maxResults: 2))
        var hits = 0
        var stopped = false
        SearchEngine.walk(request) { event in
            if case .hits(let batch) = event { hits += batch.count }
            if case .limitReached = event { stopped = true }
        }
        XCTAssertEqual(hits, 2)
        XCTAssertTrue(stopped)
    }

    func testContentSizeLimitSkipsBiggerFiles() throws {
        let big = root.appending(path: "Projects/big.txt")
        try (String(repeating: "filler ", count: 200_000) + "needle").write(to: big, atomically: true, encoding: .utf8)
        func contents(_ limits: SearchLimits) throws -> [String] {
            try search("needle", limits: limits) { $0.searchNames = false; $0.searchContents = true }.map(\.name)
        }
        XCTAssertEqual(try contents(SearchLimits()), ["big.txt"])
        XCTAssertEqual(try contents(SearchLimits(maxContentBytes: 1024 * 1024)), [])
    }

    func testNameSearchFindsFoldersAndSkipsHidden() throws {
        XCTAssertEqual(try search("invoice").map(\.name), ["Invoices"])
        XCTAssertEqual(try search("invoice") { $0.includeHidden = true }.map(\.name), [".hidden-invoice.txt", "Invoices"])
    }

    func testKindFilters() throws {
        XCTAssertEqual(try search("r") { $0.kind = .folders }.map(\.name), ["Projects"])
        XCTAssertEqual(try search("readme") { $0.kind = .files }.map(\.name), ["readme.md"])
        XCTAssertEqual(try search("readme") { $0.kind = .folders }, [])
    }

    func testContentSearchSkipsBinaryAndReportsSnippet() throws {
        let hits = try search("total due") { $0.searchNames = false; $0.searchContents = true; $0.mode = .phrase }
        XCTAssertEqual(hits.map(\.name), ["march.txt"])
        XCTAssertEqual(hits.first?.snippet?.text, "total due: 42 EUR")
        XCTAssertEqual(hits.first?.snippet?.match, NSRange(location: 0, length: 9))
        XCTAssertEqual(try search("inv") { $0.searchNames = false; $0.searchContents = true }, [])
    }

    func testNameOrContentsFindsEitherOnce() throws {
        let hits = try search("march OR due") { $0.searchContents = true; $0.mode = .boolean }
        XCTAssertEqual(hits.map(\.name), ["march.txt"])
    }

    func testTagsAndComments() throws {
        XCTAssertEqual(try search("urgent") { $0.searchNames = false; $0.searchTags = true }.map(\.name), ["plan.txt"])
        XCTAssertEqual(try search("lisbon") { $0.searchNames = false; $0.searchComments = true }.map(\.name), ["photo.jpg"])
        XCTAssertEqual(try search("lisbon"), [])
    }

    func testApplicationsCanBeLeftOut() throws {
        let app = root.appending(path: "Projects/Report Maker.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "x".write(to: app.appending(path: "report.plist"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try search("report").map(\.name), ["Report Maker.app"])
        XCTAssertEqual(try search("report") { $0.includeApplications = false }, [])

        let options = SearchOptions(includeApplications: false)
        XCTAssertTrue(SearchEngine.shouldSkipDirectory(URL(filePath: "/Applications"), options: options))
        XCTAssertFalse(SearchEngine.shouldSkipDirectory(
            URL(filePath: "/Applications/Utilities"), rootPath: "/Applications", options: options))
    }

    func testSystemFoldersArePruned() {
        let options = SearchOptions()
        XCTAssertTrue(SearchEngine.shouldSkipDirectory(URL(filePath: "/System/Library"), options: options))
        XCTAssertTrue(SearchEngine.shouldSkipDirectory(URL(filePath: "/Volumes"), options: options))
        XCTAssertFalse(SearchEngine.shouldSkipDirectory(URL(filePath: "/Users/someone/Library"), options: options))
        var all = options
        all.excludeSystemFolders = false
        XCTAssertFalse(SearchEngine.shouldSkipDirectory(URL(filePath: "/System/Library"), options: all))
        XCTAssertTrue(SearchEngine.shouldSkipDirectory(URL(filePath: "/System/Volumes"), options: all))
        XCTAssertFalse(SearchEngine.shouldSkipDirectory(
            URL(filePath: "/Library/Fonts/Extra"), rootPath: "/Library/Fonts", options: options))
    }
}

final class SearchOptionsTests: XCTestCase {
    func testOptionsSavedBeforeANewSettingStillLoad() throws {
        let saved = Data(#"{"kind":"files","searchNames":true,"searchContents":true,"mode":"regex","fuzzy":true}"#.utf8)
        let options = try JSONDecoder().decode(SearchOptions.self, from: saved)
        XCTAssertEqual(options.kind, .files)
        XCTAssertTrue(options.searchContents)
        XCTAssertEqual(options.mode, .regex)
        XCTAssertTrue(options.includeApplications)
        XCTAssertTrue(options.ignoreCase)
    }
}

@MainActor
final class SearchModelTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusModel-\(UUID().uuidString)")
        for name in ["invoice-march.txt", "invoice-april.txt", "inventory.csv", "notes.md"] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "x".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        suiteName = "FinderPlusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Every suite is a plist in ~/Library/Preferences: without this, each run leaves one behind.
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        removeSuite(named: suiteName)
    }

    private func finish(_ model: SearchModel) async throws {
        for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSearching)
    }

    func testNothingSearchesUntilFind() async throws {
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "invoice"
        model.options.kind = .files
        model.options.includeHidden = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.results.isEmpty)

        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name), ["invoice-april.txt", "invoice-march.txt"])
    }

    func testANarrowerFindKeepsMatchingResultsOnScreen() async throws {
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "inv"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.count, 3)

        model.query = "invoice"
        model.start()
        // The table narrows instead of emptying and refilling: sampled throughout the search, it
        // is never blank.
        var sawEmpty = false
        for _ in 0..<500 where model.isSearching {
            if model.results.isEmpty { sawEmpty = true }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(sawEmpty)
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name), ["invoice-april.txt", "invoice-march.txt"])
    }
}

final class TrashPermissionTests: XCTestCase {
    func testRecognisesPermissionErrors() {
        XCTAssertTrue(SearchModel.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(SearchModel.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertTrue(SearchModel.isPermissionError(wrapped))
        XCTAssertFalse(SearchModel.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testARealRefusalIsRecognised() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinderPlusLocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "keep.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertThrowsError(try FileManager.default.trashItem(at: file, resultingItemURL: nil)) { error in
            XCTAssertTrue(SearchModel.isPermissionError(error), "\(error)")
        }
    }
}

final class AppSettingsTests: XCTestCase {
    func testSettingsSavedBeforeANewSettingStillLoad() throws {
        let saved = Data(#"{"doubleClick":"reveal","maxResults":1000}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        XCTAssertEqual(settings.doubleClick, .reveal)
        XCTAssertEqual(settings.maxResults, 1000)
        XCTAssertTrue(settings.confirmTrash)
        XCTAssertEqual(settings.maxContentMegabytes, 50)
    }

    func testLimitsCarryTheSettings() {
        var settings = AppSettings()
        settings.maxContentMegabytes = 10
        settings.skippedFolderNames = ["node_modules"]
        XCTAssertEqual(settings.limits.maxContentBytes, 10 * 1024 * 1024)
        XCTAssertEqual(settings.limits.skippedFolderNames, ["node_modules"])
    }
}

final class FullDiskAccessTests: XCTestCase {
    func testReadableRefusedAndMissingProbes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinderPlusFDA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let readable = folder.appending(path: "open.db").path
        let locked = folder.appending(path: "locked.db").path
        let missing = folder.appending(path: "missing.db").path
        try "x".write(toFile: readable, atomically: true, encoding: .utf8)
        try "x".write(toFile: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        XCTAssertTrue(SearchModel.hasFullDiskAccess(probing: [missing, readable]))
        XCTAssertFalse(SearchModel.hasFullDiskAccess(probing: [missing, locked, readable]))
        XCTAssertTrue(SearchModel.hasFullDiskAccess(probing: [missing]), "nothing to test: never nag")
    }
}

final class AuditFixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "x") throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func walk(
        _ query: String, _ configure: (inout SearchOptions) -> Void = { _ in },
        isStopped: @escaping @Sendable () -> Bool = { false }
    ) throws -> [FileHit] {
        var options = SearchOptions()
        configure(&options)
        let request = try SearchRequest(roots: [root], query: query, options: options)
        var hits: [FileHit] = []
        SearchEngine.walk(request, isStopped: isStopped) { event in
            if case .hits(let batch) = event { hits += batch }
        }
        return hits.sorted { $0.name < $1.name }
    }

    // Audit 2: lowercasing "İ" doubled its length and pushed the match past the end of the text.
    func testFuzzyWithDottedCapitalIDoesNotCrashOrMisplaceTheMatch() throws {
        var options = SearchOptions()
        options.fuzzy = true
        options.ignoreDiacritics = false
        let matcher = try QueryMatcher(query: "invoice", options: options)
        let text = "İİİİ the invoice"
        let snippet = try XCTUnwrap(matcher.snippet(in: text))
        XCTAssertLessThanOrEqual(NSMaxRange(snippet.match), (snippet.text as NSString).length)
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.match), "invoice")
    }

    // Audit 2: an exact fuzzy match used to highlight one character early (" invoic").
    func testFuzzyHighlightsTheWholeExactWord() throws {
        var options = SearchOptions()
        options.fuzzy = true
        let snippet = try XCTUnwrap(try QueryMatcher(query: "invoice", options: options).snippet(in: "an invoice here"))
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.match), "invoice")
    }

    // Audit 3: `.*\.pdf` on one 100,000-character line took 48 seconds.
    func testContentWildcardOnALongLineIsFast() throws {
        var options = SearchOptions()
        options.mode = .wildcards
        let matcher = try QueryMatcher(query: "*.pdf", options: options, anchorsWildcards: false)
        let line = String(repeating: "a", count: 200_000)
        let started = ContinuousClock.now
        XCTAssertFalse(matcher.matches(line))
        XCTAssertTrue(matcher.matches(line + " report.pdf"))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(QueryMatcher.wildcardPattern("*.pdf*", anchored: false), "\\.pdf")
        XCTAssertEqual(QueryMatcher.wildcardPattern("*.pdf", anchored: true), "\\A.*\\.pdf\\z")

        // A `*` in the middle used to become `.*`, which ICU rescans from every match of the
        // first piece — quadratic on one long line. Trimming the ends never covered it.
        let middle = try QueryMatcher(query: "e*q", options: options, anchorsWildcards: false)
        let long = String(repeating: "e", count: 500_000)
        let middleStarted = ContinuousClock.now
        XCTAssertFalse(middle.matches(long))
        XCTAssertTrue(middle.matches(long + "q"))
        XCTAssertFalse(middle.matches("e\nq"), "`.*` never crossed a line break; the pieces must not either")
        XCTAssertLessThan(middleStarted.duration(to: .now), .seconds(1))
    }

    // Audit 3: Stop now reaches the walk and its content workers.
    func testAStoppedWalkReportsNothing() throws {
        for index in 0..<50 { _ = try write("file\(index).txt", "needle") }
        let hits = try walk("needle", { $0.searchNames = false; $0.searchContents = true }, isStopped: { true })
        XCTAssertEqual(hits, [])
    }

    // Audit 10: a query of exclusions alone now says why instead of clearing the results.
    // Any Word used to fall through to `.empty`, which the window treats as "no query" and
    // silently ignores — so it is asserted alongside the default mode.
    func testExclusionsOnlyQueryExplainsItself() {
        for mode in [MatchMode.allWords, .anyWord] {
            var options = SearchOptions()
            options.mode = mode
            XCTAssertThrowsError(try QueryMatcher(query: "-draft", options: options)) { error in
                guard case QueryError.onlyExclusions = error else { return XCTFail("\(mode): \(error)") }
            }
        }
    }

    // Stopping an unstarted walk proves little: a stop that arrives while content is being read
    // must also halt it. The walk polls once per item and queues a content batch every 64 files,
    // whose workers each poll once, so polls 65–128 belong to the first batch and the stop is
    // timed to land inside it. What this cannot show is whether the workers themselves skip their
    // reads — the walk's own check before item 65 halts it either way, and the hit count cannot
    // tell the two apart. It guards the walk-level stop under batch load: the second batch never
    // starts, and far fewer than every file is reported.
    func testStoppingMidWalkHaltsIt() throws {
        for index in 0..<200 { _ = try write("file\(index).txt", "needle") }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let hits = try walk("needle", { $0.searchNames = false; $0.searchContents = true }) {
            polls.withLock { $0 += 1; return $0 > 100 }
        }
        XCTAssertLessThanOrEqual(hits.count, 64)
        XCTAssertLessThan(hits.count, 200)
    }

    // Audit 11: another user whose name starts with this one's must not become "~b/…".
    func testDisplayParentOnlyAbbreviatesTheRealHome() {
        let sibling = FileHit(
            url: URL(filePath: NSHomeDirectory() + "b/Documents/x.txt"), name: "x.txt", isFolder: false,
            size: 1, modified: .now, kind: "Text")
        XCTAssertFalse(sibling.displayParent.hasPrefix("~"))
        let own = FileHit(
            url: URL(filePath: NSHomeDirectory() + "/Documents/x.txt"), name: "x.txt", isFolder: false,
            size: 1, modified: .now, kind: "Text")
        XCTAssertEqual(own.displayParent, "~/Documents")
    }

    // Audit 9: a folder that is gone is named as missing, not blamed on Full Disk Access.
    func testMissingFolderIsReportedAsMissing() async {
        do {
            _ = try await SearchModel.resolveRoots(for: .folder(root.appending(path: "gone").path))
            XCTFail("expected an error")
        } catch LocationError.missingFolder {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testDateSizeAndKindFilters() throws {
        let old = try write("old-report.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        _ = try write("new-report.txt")
        _ = try write("report-photo.png")
        _ = try write("big-report.txt", String(repeating: "x", count: 1_200_000))

        XCTAssertEqual(try walk("report") { $0.modified = .month }.map(\.name),
                       ["big-report.txt", "new-report.txt", "report-photo.png"])
        XCTAssertEqual(try walk("report") { $0.size = .over1MB }.map(\.name), ["big-report.txt"])
        XCTAssertEqual(try walk("report") { $0.size = .under1MB; $0.excludedKinds = [.images] }.map(\.name),
                       ["new-report.txt", "old-report.txt"])
        XCTAssertTrue(try walk("new-report").allSatisfy { $0.created > .distantPast })
    }

    func testZipEntriesAreListedWhenAsked() throws {
        _ = try write("src/Reports/invoice-march.pdf")
        _ = try write("src/notes.txt")
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qr", "bundle.zip", "src"]
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: root.appending(path: "src"))

        XCTAssertEqual(try walk("invoice"), [])
        let hits = try walk("invoice") { $0.includeArchiveContents = true }
        XCTAssertEqual(hits.map(\.name), ["invoice-march.pdf"])
        let entry = try XCTUnwrap(hits.first)
        XCTAssertTrue(entry.isArchiveEntry)
        XCTAssertEqual(entry.url.lastPathComponent, "bundle.zip")
        XCTAssertTrue(entry.fullPath.hasSuffix("bundle.zip/src/Reports/invoice-march.pdf"))
        XCTAssertNotEqual(entry.id, entry.url.path)
        XCTAssertEqual(try walk("reports") { $0.includeArchiveContents = true; $0.kind = .folders }.map(\.name),
                       ["Reports"])
    }

    // `bsdtar` writes "./docs/report.txt", and the "." part read as a hidden folder.
    func testZipEntriesUnderADotPrefixAreNotHidden() throws {
        _ = try write("docs/invoice-april.txt")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["-a", "-cf", "dotted.zip", "./docs"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        try FileManager.default.removeItem(at: root.appending(path: "docs"))
        XCTAssertTrue(SearchEngine.zipEntries(of: root.appending(path: "dotted.zip")).contains("./docs/invoice-april.txt"))

        XCTAssertEqual(try walk("invoice") { $0.includeArchiveContents = true }.map(\.name), ["invoice-april.txt"])
    }

    // A folder copied into itself kept copying its own copy, about a hundred levels deep.
    func testAFolderIsNeverCopiedOrMovedIntoItself() throws {
        _ = try write("Projects/inner/plan.txt")
        let folder = root.appending(path: "Projects")
        for destination in [folder, folder.appending(path: "inner")] {
            for kind in [SearchModel.Transfer.copy, .move] {
                let outcome = SearchModel.perform(kind, [folder], into: destination)
                XCTAssertEqual(outcome.done, [:])
                XCTAssertEqual(outcome.failed.count, 1)
                XCTAssertTrue(outcome.failed[0].contains("into itself"), outcome.failed[0])
            }
        }
        XCTAssertEqual(
            try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted(), ["inner", "inner/plan.txt"])
        // A sibling whose name only starts the same is not inside it.
        let sibling = root.appending(path: "Projects-old")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        XCTAssertEqual(SearchModel.perform(.copy, [folder], into: sibling).failed, [])
    }

    // macOS files `.ts` as video and `.plist`, `.eml` and `.pem` as types that are not text, so
    // content search turned them away unread.
    func testContentSearchReadsTextWhateverItsDeclaredType() throws {
        for name in ["index.ts", "agent.plist", "mail.eml", "key.pem", "notes.txt"] {
            _ = try write(name, "the needleagent is here")
        }
        let video = root.appending(path: "clip.ts")
        try Data([0x47, 0x40, 0x00, 0x10] + Array("needleagent".utf8)).write(to: video)
        XCTAssertEqual(
            try walk("needleagent") { $0.searchNames = false; $0.searchContents = true }.map(\.name),
            ["agent.plist", "index.ts", "key.pem", "mail.eml", "notes.txt"])
    }

    // One invalid byte failed the strict UTF-8 decode, and Windows-1252 turned every "é" into "Ã©".
    func testOneBadByteKeepsAFileUTF8() throws {
        let flawed = SearchEngine.decode(Data("café crème brûlée ".utf8) + [0xFF] + Data(" fin".utf8))
        XCTAssertEqual(flawed, "café crème brûlée \u{FFFD} fin")
        // A real Windows-1252 file still reads as one.
        XCTAssertEqual(SearchEngine.decode(Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x92, 0x73])), "café ’s")
    }

    // UTF-8 got that lossy fallback; UTF-16 had none, so one lone surrogate made a whole file
    // unsearchable.
    func testUTF16WithALoneSurrogateStillReads() {
        var data = Data([0xFF, 0xFE])
        data += "ok ".data(using: .utf16LittleEndian)!
        data += Data([0x00, 0xD8])  // a high surrogate with no partner
        data += " go".data(using: .utf16LittleEndian)!
        XCTAssertEqual(SearchEngine.decode(data), "ok \u{FFFD} go")
    }

    // `.ts` declares an MPEG-2 type and `.mts` AVCHD, so excluding "Video" hid TypeScript files
    // from name searches too, and their Kind read "MPEG-2 transport stream".
    func testVideoExclusionDoesNotHideTypeScript() throws {
        _ = try write("config.ts", "export const x = 1")
        _ = try write("config.mts", "export const x = 1")
        _ = try write("clip.mp4", "not really a video")
        let hits = try walk("c") { $0.excludedKinds = [.video] }
        XCTAssertEqual(hits.map(\.name), ["config.mts", "config.ts"])
        XCTAssertEqual(hits.map(\.kind), ["MTS File", "TS File"])
    }

    // `.mts` is exempt from the Video exclusion for TypeScript, which let a camcorder's AVCHD
    // clip through too.
    func testVideoExclusionStillHidesRealTransportStreams() throws {
        _ = try write("config.mts", "export const x = 1")
        _ = try write("Cargo.mts", "G is for guitar")
        var packets = Data()
        for _ in 0..<4 { packets += Data([0x00, 0x00, 0x00, 0x00, 0x47]) + Data(repeating: 0x11, count: 187) }
        try packets.write(to: root.appending(path: "clip.MTS"))
        var plain = Data()
        for _ in 0..<4 { plain += Data([0x47]) + Data(repeating: 0x22, count: 187) }
        try plain.write(to: root.appending(path: "tv.ts"))
        XCTAssertEqual(try walk("c") { $0.excludedKinds = [.video] }.map(\.name), ["Cargo.mts", "config.mts"])
    }

    // The sniff opens the file: a FIFO named x.ts blocked the walk for good, and it ran before
    // the name was even tested.
    func testTransportStreamSniffSkipsFIFOsAndNonMatches() throws {
        XCTAssertEqual(mkfifo(root.appending(path: "fifo.ts").path, 0o644), 0)
        _ = try write("other.ts", "export {}")
        XCTAssertEqual(try walk("other") { $0.excludedKinds = [.video] }.map(\.name), ["other.ts"])
        XCTAssertEqual(try walk("fifo") { $0.excludedKinds = [.video] }.map(\.name), ["fifo.ts"])
    }

    // A timeout used to be a silent miss: the status bar must say the search could not check them.
    func testRegexTimeoutsAreReportedWithTheProgress() throws {
        let name = String(repeating: "a", count: 48) + "!.txt"
        _ = try write(name, "x")
        var options = SearchOptions()
        options.mode = .regex
        let request = try SearchRequest(
            roots: [root], query: "^(a+)+$", options: options, matchBudget: .milliseconds(50))
        var timedOut = 0
        var hits = 0
        SearchEngine.walk(request) { event in
            if case .hits(let batch) = event { hits += batch.count }
            if case .progress(_, _, _, let count) = event { timedOut = max(timedOut, count) }
        }
        XCTAssertEqual(hits, 0)
        XCTAssertGreaterThanOrEqual(timedOut, 1)
    }

    // A file the search could not open looked exactly like a file that does not contain the words:
    // found nothing, counted nothing.
    func testUnreadableFilesAreCountedNotSilentlySkipped() throws {
        _ = try write("open.txt", "the needle is here")
        let locked = try write("locked.txt", "the needle is here")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        var options = SearchOptions()
        options.searchNames = false
        options.searchContents = true
        let request = try SearchRequest(roots: [root], query: "needle", options: options)
        var names: [String] = []
        var unreadable = 0
        SearchEngine.walk(request) { event in
            if case .hits(let batch) = event { names += batch.map(\.name) }
            if case .progress(_, _, let count, _) = event { unreadable = max(unreadable, count) }
        }
        XCTAssertEqual(names, ["open.txt"])
        XCTAssertGreaterThanOrEqual(unreadable, 1)
    }

    func testMarkupDecodesNumericAndNamedEntities() {
        XCTAssertEqual(
            DocumentText.markupText("<p>caf&eacute; &#233;t&#xE9; don&rsquo;t &amp;lt; &bogus; &yuml;&iexcl;</p>"),
            " café été don’t &lt; &bogus; ÿ¡ ")
    }

    func testCSVExportNeutralisesFormulas() {
        XCTAssertEqual(SearchModel.csvField("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(SearchModel.csvField("+1"), "'+1")
        XCTAssertEqual(SearchModel.csvField("@sum"), "'@sum")
        XCTAssertEqual(SearchModel.csvField("-draft, v2"), "\"'-draft, v2\"")
        XCTAssertEqual(SearchModel.csvField("report.pdf"), "report.pdf")
    }

    // `zipinfo` printed non-ASCII entry names in a lossy form, so "Straße.txt" in an archive could
    // never be found by name. Neither name decomposes, so filesystem normalization cannot blur it.
    func testZipEntryNamesKeepTheirNonASCIICharacters() throws {
        let names = ["Straße.txt", "Kenny\u{2019}s notes.txt"]
        for name in names { _ = try write(name) }
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "names.zip"] + names
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        XCTAssertEqual(SearchEngine.zipEntries(of: root.appending(path: "names.zip")).sorted(), names.sorted())
    }

    // Only an entry's own name was checked for a leading dot, so everything inside an archived
    // ".git" folder surfaced even with hidden files excluded.
    func testArchiveEntriesUnderAHiddenFolderStayHidden() throws {
        _ = try write("proj/.git/HEAD")
        _ = try write("proj/readme.txt")
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qr", "bundle.zip", "proj"]
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: root.appending(path: "proj"))

        XCTAssertEqual(try walk("head") { $0.includeArchiveContents = true }, [])
        XCTAssertEqual(try walk("readme") { $0.includeArchiveContents = true }.map(\.name), ["readme.txt"])
        // Proves the archive really holds the entry, so the empty result above is the filter.
        XCTAssertEqual(try walk("head") { $0.includeArchiveContents = true; $0.includeHidden = true }.map(\.name),
                       ["HEAD"])
    }
}

@MainActor
final class AuditModelTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusAuditModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["invoice-march.txt", "notes.md", "notes-old.md"] {
            try "x".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        suiteName = "FinderPlusAudit-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Every suite is a plist in ~/Library/Preferences: without this, each run leaves one behind.
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        removeSuite(named: suiteName)
    }

    private func finish(_ model: SearchModel) async throws {
        for _ in 0..<300 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSearching)
    }

    // Audit 1: a replaced search's events must not land in the new results.
    func testAReplacedSearchLeavesNothingBehind() async throws {
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "invoice"
        model.start()
        model.query = "notes"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name).sorted(), ["notes-old.md", "notes.md"])
    }

    // Audit 10: Return runs the same checks as the Find button.
    func testNothingTickedExplainsInsteadOfWalking() {
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "notes"
        model.options.searchNames = false
        model.start()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    }

    // A saved sort on the Match column left a name-only search in walk order: every snippet is empty
    // and the column is hidden, so nothing showed it or let it be changed.
    func testMatchSortFallsBackToNameWhenNothingHasASnippet() {
        let model = SearchModel(defaults: defaults)
        model.sortOrder = [KeyPathComparator(\FileHit.snippetText)]
        model.results = ["b.txt", "c.txt", "a.txt"].map {
            FileHit(url: URL(filePath: "/tmp/\($0)"), name: $0, isFolder: false, size: 1, modified: .now, kind: "Text")
        }
        model.resort()
        XCTAssertEqual(model.results.map(\.name), ["a.txt", "b.txt", "c.txt"])
    }

    func testSortOrderIsRemembered() {
        let first = SearchModel(defaults: defaults)
        first.sortOrder = [KeyPathComparator(\FileHit.size, order: .reverse)]
        let second = SearchModel(defaults: defaults)
        XCTAssertEqual(second.sortOrder.first?.keyPath, \FileHit.size as AnyKeyPath)
        XCTAssertEqual(second.sortOrder.first?.order, .reverse)
    }
}

final class DocumentTextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusDocs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a zip whose members are the given files, the way Office and EPUB files are made.
    private func makeZip(_ name: String, _ members: [String: String], order: [String]? = nil) throws -> URL {
        let staging = root.appending(path: "staging-\(name)")
        for (path, text) in members {
            let url = staging.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        // `order` fixes the archive order, which `bsdtar -xO` writes in.
        zip.arguments = ["-qr", root.appending(path: name).path] + (order ?? ["."])
        try zip.run()
        zip.waitUntilExit()
        return root.appending(path: name)
    }

    func testMarkupBecomesText() {
        XCTAssertEqual(
            DocumentText.markupText("<p>Q3 <b>report</b></p><script>var x = 1</script><a:t>total</a:t> &amp; more"),
            " Q3 report total & more")
    }

    func testSpreadsheetPresentationAndEbookText() throws {
        let xlsx = try makeZip("book.xlsx", [
            "xl/sharedStrings.xml": "<sst><si><t>Quarterly</t></si><si><t>revenue</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<sheetData><row><c><v>4242</v></c></row></sheetData>",
        ])
        let text = try XCTUnwrap(SearchEngine.contentText(of: xlsx, size: 1))
        XCTAssertTrue(text.contains("Quarterly revenue"), text)
        XCTAssertTrue(text.contains("4242"))

        // Runs inside one paragraph fuse, as PowerPoint renders them; paragraphs stay apart. The
        // old expectation here ("Launch plan" from two bare <a:t> runs) enshrined the splitting.
        let pptx = try makeZip("deck.pptx", ["ppt/slides/slide1.xml":
            "<p:sld><a:p><a:r><a:t>Quar</a:t></a:r><a:r><a:t>terly</a:t></a:r></a:p><a:p><a:r><a:t>plan</a:t></a:r></a:p></p:sld>"])
        let slide = try XCTUnwrap(SearchEngine.contentText(of: pptx, size: 1))
        XCTAssertTrue(slide.contains("Quarterly"), slide)
        XCTAssertTrue(slide.contains(" plan"), slide)
        XCTAssertFalse(slide.contains("terlyplan"), slide)

        let epub = try makeZip("book.epub", ["OEBPS/chapter1.xhtml": "<html><body><p>Call me Ishmael.</p></body></html>"])
        XCTAssertTrue(try XCTUnwrap(SearchEngine.contentText(of: epub, size: 1)).contains("Call me Ishmael."))
    }

    func testHTMLIsSearchedWithoutItsTags() throws {
        let page = root.appending(path: "page.html")
        try "<html><head><style>.a{}</style></head><body><h1>Welcome</h1><p>home page</p></body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let text = try XCTUnwrap(SearchEngine.contentText(of: page, size: 100))
        XCTAssertTrue(text.contains("Welcome home page"), text)
        XCTAssertFalse(text.contains("<h1>"))
    }

    // `unzip` expanded `[`, `?` and `*` in the archive's own file name, so "Q[1].xlsx" was read
    // as its sibling "Q1.xlsx": the glob file's text was never searched, and its hit and preview
    // showed the other file's.
    func testZipTextReadsTheNamedArchiveNotAGlobSibling() throws {
        _ = try makeZip("Q1.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>ALPHA</t></si></sst>"])
        let bracketed = try makeZip("Q[1].xlsx", ["xl/sharedStrings.xml": "<sst><si><t>BRAVO</t></si></sst>"])
        let text = try XCTUnwrap(SearchEngine.contentText(of: bracketed, size: 1))
        XCTAssertTrue(text.contains("BRAVO"), text)
        XCTAssertFalse(text.contains("ALPHA"), text)
    }

    // A t="s" cell's <v> is an index into sharedStrings, not a value: left in, a content search
    // for "17" matched every workbook with that many unique strings.
    func testSharedStringIndicesAreNotSearchableText() throws {
        let xlsx = try makeZip("indices.xlsx", [
            "xl/sharedStrings.xml": "<sst><si><t>apple</t></si><si><t>banana</t></si></sst>",
            "xl/worksheets/sheet1.xml":
                "<sheetData><row><c r=\"A1\" t=\"s\"><v>17</v></c><c r=\"B1\"><v>4242</v></c></row></sheetData>",
        ])
        let text = try XCTUnwrap(SearchEngine.contentText(of: xlsx, size: 1))
        XCTAssertTrue(text.contains("apple"), text)
        XCTAssertTrue(text.contains("4242"), text)
        XCTAssertFalse(text.contains("17"), text)
    }

    // Every tag used to become a space, splitting words the markup only styles: a drop-cap span,
    // a word split across runs, a soft hyphen.
    func testInlineTagsDoNotSplitWords() {
        XCTAssertEqual(DocumentText.markupText("<p><span class=\"dropcap\">Q</span>uarterly results</p>"),
                       " Quarterly results ")
        XCTAssertEqual(DocumentText.markupText("<si><r><rPr/><t>Quar</t></r><r><t>terly</t></r></si>"),
                       " Quarterly ")
        XCTAssertEqual(DocumentText.markupText("<p>one</p><p>two</p>"), " one two ")
        XCTAssertEqual(DocumentText.markupText("<td>a</td><td>b</td>"), " a b ")
        XCTAssertEqual(DocumentText.markupText("Quar&shy;terly"), "Quarterly")
        XCTAssertEqual(DocumentText.markupText("Quar\u{AD}terly"), "Quarterly")
    }

    // With no document type given, AppKit sniffed an HTML ".doc" (a common web-app export) and
    // handed it to WebKit, which waited out a 63-second load timeout on any remote image — one
    // such file froze its whole content batch — and then returned the raw tags.
    func testAnHTMLFileWearingADocExtensionReadsAsTextQuickly() throws {
        let doc = root.appending(path: "report.doc")
        try """
            <!DOCTYPE html><html><head><img src="https://example.invalid/logo.png"></head>\
            <body><p>Quarterly figures attached</p></body></html>
            """.write(to: doc, atomically: true, encoding: .utf8)
        let started = ContinuousClock.now
        let text = try XCTUnwrap(SearchEngine.contentText(of: doc, size: 200))
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertTrue(text.contains("Quarterly figures attached"), text)
        XCTAssertFalse(text.contains("<p>"), text)

        // A real rich-text document still parses through its own reader.
        let rtf = root.appending(path: "note.rtf")
        try #"{\rtf1\ansi Hello from RTF}"#.write(to: rtf, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(SearchEngine.contentText(of: rtf, size: 100)).contains("Hello from RTF"))
    }

    // Swift Regex passes over a big worksheet cost 1.2 GB and seconds between Stop checks.
    func testStoppingInterruptsALargeMarkupPassAtOnce() {
        let markup = String(repeating: "<c r=\"A1\"><v>1</v></c>", count: 2_000_000)
        let started = ContinuousClock.now
        XCTAssertEqual(DocumentText.markupText(markup, isStopped: { true }), "")
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
    }

    // Only so many zip and Office extractions run at once: one per core held every file's XML.
    func testHeavyExtractionsAreCapped() {
        let running = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            _ = DocumentText.withHeavySlot(isStopped: { false }) { () -> Int? in
                running.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                Thread.sleep(forTimeInterval: 0.05)
                running.withLock { $0.now -= 1 }
                return 1
            }
        }
        let peak = running.withLock { $0.peak }
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThanOrEqual(peak, 1)
    }

    // A self-closing <script/> took everything up to the next </script> with it, an EPUB chapter
    // among it; a mixed-case <SCRIPT> was never removed.
    func testSelfClosingAndMixedCaseScriptTags() {
        let text = DocumentText.markupText(
            "<p>Call me</p><script src=\"a.js\"/><p>Ishmael</p><SCRIPT>var hidden</script><style>.x{}</STYLE><p>end</p>")
        XCTAssertTrue(text.contains("Ishmael"), text)
        XCTAssertTrue(text.contains("end"), text)
        XCTAssertFalse(text.contains("hidden"), text)
        XCTAssertFalse(text.contains(".x"), text)
    }

    // Excel's <rPr> always carries <sz>, <color> and <rFont>, PowerPoint's <a:rPr> its fills and
    // fonts: each child became a space inside the word.
    func testRunPropertiesDoNotSplitWords() {
        XCTAssertEqual(
            DocumentText.markupText(
                "<si><r><rPr><sz val=\"11\"/><color rgb=\"FF\"/><rFont val=\"Calibri\"/></rPr><t>Quar</t></r>"
                    + "<r><rPr><b/><family val=\"2\"/></rPr><t>terly</t></r></si>"),
            " Quarterly ")
        XCTAssertEqual(
            DocumentText.markupText(
                "<a:p><a:r><a:rPr lang=\"en\"><a:solidFill><a:srgbClr val=\"000\"/></a:solidFill><a:latin typeface=\"Arial\"/></a:rPr>"
                    + "<a:t>Quar</a:t></a:r><a:r><a:rPr/><a:t>terly</a:t></a:r></a:p>"),
            " Quarterly ")
    }

    // Only a:r and a:t were known as runs, so another prefix split the word.
    func testPrefixedRunsDoNotSplitWords() {
        XCTAssertEqual(DocumentText.markupText("<x:r><x:t>Quar</x:t></x:r><x:r><x:t>terly</x:t></x:r>"), "Quarterly")
        XCTAssertEqual(DocumentText.markupText("<w:r><w:t>Quar</w:t></w:r><w:r><w:t>terly</w:t></w:r>"), "Quarterly")
        XCTAssertEqual(DocumentText.markupText("a<text:s/>b"), "a b", "ODF's text:s is a space")
    }

    // A password-protected docx is an OLE container: the readers refuse it and the sniff calls it binary.
    func testEncryptedWordFileIsCountedUnreadable() throws {
        let locked = root.appending(path: "locked.docx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600)).write(to: locked)
        var count = 0
        XCTAssertNil(SearchEngine.contentText(of: locked, size: 608, onUnreadable: { count += 1 }))
        XCTAssertEqual(count, 1)
    }

    // The preview queued behind the search for one of the three slots.
    func testPreviewExtractionIsNotHeldUpByBusySlots() throws {
        let xlsx = try makeZip("busy.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>apple</t></si></sst>"])
        let release = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            DispatchQueue.global().async {
                _ = DocumentText.withHeavySlot(isStopped: { false }) { () -> Int? in
                    held.signal()
                    release.wait()
                    return 1
                }
            }
        }
        for _ in 0..<3 { held.wait() }
        defer { for _ in 0..<3 { release.signal() } }
        let text = SearchEngine.contentText(of: xlsx, size: 1, isStopped: { false }, capsExtractions: false)
        XCTAssertEqual(text?.contains("apple"), true)
    }

    // Ruby annotations fused into the base text: "漢<rt>かん</rt>字" read "漢かん字".
    func testRubyAnnotationsAreLeftOut() {
        XCTAssertEqual(DocumentText.markupText("<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp>字</ruby>"), "漢字")
    }

    // Prefixed cells kept their indices, and after a self-closing <c t="s"/> the lazy body ate the
    // next cell's value.
    func testSharedStringCellsWithPrefixesAndSelfClosingForm() throws {
        let xlsx = try makeZip("cells.xlsx", [
            "xl/sharedStrings.xml": "<sst><si><t>apple</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<sheetData><row><x:c r=\"A1\" t=\"s\"><x:v>31337</x:v></x:c>"
                + "<c r=\"B1\" t=\"s\"/><c r=\"C1\"><v>98765</v></c></row></sheetData>",
        ])
        let text = try XCTUnwrap(SearchEngine.contentText(of: xlsx, size: 1))
        XCTAssertTrue(text.contains("98765"), text)
        XCTAssertFalse(text.contains("31337"), text)
    }

    // `bsdtar -xO` writes members in archive order and Excel stores sharedStrings.xml after the
    // worksheets, so a workbook whose sheets filled the budget never had its words read.
    func testSharedStringsAreReadBeforeTheSheets() throws {
        let sheet = "<sheetData>" + String(repeating: "<row><c><v>1</v></c></row>", count: 8000) + "</sheetData>"
        let xlsx = try makeZip("late.xlsx", [
            "xl/worksheets/sheet1.xml": sheet,
            "xl/sharedStrings.xml": "<sst><si><t>Lighthouse</t></si></sst>",
        ], order: ["xl/worksheets/sheet1.xml", "xl/sharedStrings.xml"])
        let text = try XCTUnwrap(SearchEngine.contentText(of: xlsx, size: 1, maxBytes: 100_000))
        XCTAssertTrue(text.contains("Lighthouse"), text)
    }

    func testMoreOfficeExtensionsHaveReaders() {
        for ext in ["xlsx", "xlsm", "xltx", "xltm"] {
            XCTAssertEqual(DocumentText.zipMembers(forExtension: ext)?.first, "xl/sharedStrings.xml", ext)
        }
        for ext in ["pptx", "pptm", "ppsx", "ppsm", "potx", "potm"] {
            XCTAssertEqual(DocumentText.zipMembers(forExtension: ext)?.first, "ppt/slides/*.xml", ext)
        }
    }

    // A file the search could not make sense of looked like one that lacked the words.
    func testEncryptedOfficeAndBrokenPDFAreCountedUnreadable() throws {
        // Encrypted workbooks are OLE containers behind a zip name.
        let encrypted = root.appending(path: "locked.xlsx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 7, count: 600)).write(to: encrypted)
        var count = 0
        XCTAssertNil(SearchEngine.contentText(of: encrypted, size: 600, onUnreadable: { count += 1 }))
        XCTAssertEqual(count, 1)

        let broken = root.appending(path: "broken.pdf")
        try Data("not a pdf at all".utf8).write(to: broken)
        count = 0
        XCTAssertNil(SearchEngine.contentText(of: broken, size: 16, onUnreadable: { count += 1 }))
        XCTAssertEqual(count, 1)

        // A pattern with no member behind it fails too, but the workbook was read: not counted.
        let fine = try makeZip("fine.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>x</t></si></sst>"])
        count = 0
        XCTAssertNotNil(SearchEngine.contentText(of: fine, size: 1, onUnreadable: { count += 1 }))
        XCTAssertEqual(count, 0)
    }

    // `looksLikeHTML` ran on every sniffed file, so a PHP view that opened with `<!doctype html`
    // came back as its text with every tag and `<?php … ?>` block stripped.
    func testTemplatesOpeningWithADoctypeAreNotStrippedAsHTML() throws {
        let source = "<!doctype html>\n<html><body><?php if ($claim->getId() > 0): ?>Claim <?= $claim->getId() ?><?php endif ?></body></html>"
        for name in ["view.php", "view.erb", "page.twig", "notes.md", "plain.txt", "app.js"] {
            let url = root.appending(path: name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(SearchEngine.contentText(of: url, size: Int64(source.utf8.count)), source, name)
        }
        // A page typed as HTML still reads as what it says.
        let page = root.appending(path: "page.html")
        try source.write(to: page, atomically: true, encoding: .utf8)
        XCTAssertFalse(try XCTUnwrap(SearchEngine.contentText(of: page, size: Int64(source.utf8.count))).contains("<body>"))
    }

    private func textutil(_ format: String, from text: String, as name: String) throws -> URL {
        let source = root.appending(path: "source-\(name).txt")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let output = root.appending(path: name)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/textutil")
        process.arguments = ["-convert", format, "-output", output.path, source.path]
        try process.run()
        process.waitUntilExit()
        return output
    }

    // The forced reader failed on a file named for another format: RTF saved as .doc came back
    // as raw RTF, and a docx named .doc, a doc named .docx and an odt named .doc as nothing.
    func testWordFilesWithTheWrongExtensionAreReadByTheirContents() throws {
        let words = "Lighthouse keeper"
        for (format, name) in [("rtf", "rtf-as.doc"), ("docx", "docx-as.doc"), ("doc", "doc-as.docx"), ("odt", "odt-as.doc")] {
            let real = try textutil(format, from: words, as: "real.\(format)")
            let misnamed = root.appending(path: name)
            try FileManager.default.copyItem(at: real, to: misnamed)
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: misnamed.path)[.size] as? Int64)
            let text = try XCTUnwrap(SearchEngine.contentText(of: misnamed, size: size), name)
            XCTAssertTrue(text.contains(words), "\(name): \(text)")
            XCTAssertFalse(text.contains("rtf1"), "\(name): \(text)")
        }
        let wordML = root.appending(path: "wordml.doc")
        let xml = "<?xml version=\"1.0\"?><w:wordDocument xmlns:w=\"http://schemas.microsoft.com/office/word/2003/wordml\">"
            + "<w:body><w:p><w:r><w:t>Lighthouse keeper</w:t></w:r></w:p></w:body></w:wordDocument>"
        try xml.write(to: wordML, atomically: true, encoding: .utf8)
        let text = try XCTUnwrap(SearchEngine.contentText(of: wordML, size: Int64(xml.utf8.count)))
        XCTAssertTrue(text.contains(words), text)
        XCTAssertFalse(text.contains("<w:"), text)
    }

    private func retypePackage(_ package: URL, from old: String, to new: String) throws {
        let staging = root.appending(path: "retype-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (tool, arguments) in [("/usr/bin/bsdtar", ["-xf", package.path, "-C", staging.path])] {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
        let types = staging.appending(path: "[Content_Types].xml")
        try String(contentsOf: types, encoding: .utf8).replacingOccurrences(of: old, with: new)
            .write(to: types, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: package)
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-qr", package.path, "."]
        try zip.run()
        zip.waitUntilExit()
    }

    // .docm, .dotx, .dotm, .dot and .ott conform to none of the reader types and were never read.
    func testMacroAndTemplateWordFormatsAreRead() throws {
        for (format, name) in [("docx", "macro.docm"), ("docx", "template.dotx"), ("docx", "template.dotm"),
                               ("doc", "template.dot"), ("odt", "template.ott")] {
            let real = try textutil(format, from: "Lighthouse keeper", as: "real-\(name).\(format)")
            let copy = root.appending(path: name)
            try FileManager.default.copyItem(at: real, to: copy)
            // Office writes the variant's own content type into the package, not the docx one.
            if format == "docx" {
                try retypePackage(copy, from: "wordprocessingml.document.main+xml",
                                  to: name.hasSuffix("docm") ? "wordprocessingml.document.macroEnabled.main+xml"
                                      : "wordprocessingml.template.main+xml")
            }
            let text = try XCTUnwrap(SearchEngine.contentText(of: copy, size: 1), name)
            XCTAssertTrue(text.contains("Lighthouse keeper"), "\(name): \(text)")
        }
    }

    func testTextIsRecognisedInAnImage() throws {
        let size = NSSize(width: 900, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("RECEIPT TOTAL 42" as NSString).draw(
                at: NSPoint(x: 40, y: 70),
                withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
            return true
        }
        let png = root.appending(path: "receipt.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)

        XCTAssertNil(SearchEngine.contentText(of: png, size: 1000), "images are read only when asked")
        let text = try XCTUnwrap(SearchEngine.contentText(of: png, size: 1000, recognizeText: true))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("receipt total"), text)
    }

    func testPhotoMetadataAndPermissions() throws {
        let url = root.appending(path: "photo.jpg")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:30:00"],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        let metadata = try XCTUnwrap(DocumentText.metadataText(of: url))
        for expected in ["Canon", "EOS R5", "taken 2024-05-01 10:30", "8×8", "rw-r-----", "owner \(NSUserName())"] {
            XCTAssertTrue(metadata.contains(expected), "\(expected) missing from \(metadata)")
        }
        XCTAssertEqual(DocumentText.permissions(0o755), "rwxr-xr-x")
    }

    func testMetadataSearchFindsPhotosByCamera() throws {
        let url = root.appending(path: "IMG_0001.jpg")
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "EOS R5"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        var options = SearchOptions()
        options.searchNames = false
        options.searchMetadata = true
        let request = try SearchRequest(roots: [root], query: "eos r5", options: options)
        var hits: [FileHit] = []
        SearchEngine.walk(request) { if case .hits(let batch) = $0 { hits += batch } }
        XCTAssertEqual(hits.map(\.name), ["IMG_0001.jpg"])
        // With several words, the highlight marks where the first one matched.
        XCTAssertEqual(hits.first.map { ($0.snippetText as NSString).substring(with: $0.snippet!.match) }, "EOS")
    }

    func testAStoppedReadReturnsNothing() throws {
        let text = root.appending(path: "notes.txt")
        try "plain words".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(SearchEngine.contentText(of: text, size: 11, isStopped: { false }), "plain words")
        XCTAssertNil(SearchEngine.contentText(of: text, size: 11, isStopped: { true }))

        let docx = try makeZip("book.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>Quarterly</t></si></sst>"])
        let members = try XCTUnwrap(DocumentText.zipMembers(forExtension: "xlsx"))
        let maxBytes = SearchLimits().maxContentBytes
        XCTAssertNotNil(DocumentText.zipText(of: docx, members: members, maxBytes: maxBytes, isStopped: { false }))
        XCTAssertNil(DocumentText.zipText(of: docx, members: members, maxBytes: maxBytes, isStopped: { true }))
    }

    func testABinaryFileIsTurnedDownButUTF16TextIsRead() throws {
        let binary = root.appending(path: "blob.zzqx")
        try Data([0x41, 0x42, 0x00, 0x43, 0x44]).write(to: binary)
        XCTAssertNil(SearchEngine.contentText(of: binary, size: 5))

        let utf16 = root.appending(path: "wide.zzqx")
        let data = try XCTUnwrap("hello wide world".data(using: .utf16))
        XCTAssertTrue(data.contains(0), "UTF-16 of ASCII text carries NUL bytes")
        try data.write(to: utf16)
        XCTAssertEqual(SearchEngine.contentText(of: utf16, size: Int64(data.count)), "hello wide world")
    }

    func testIsBinaryLooksForANulInTheFirst8KBUnlessThereIsAUTF16Mark() {
        XCTAssertTrue(SearchEngine.isBinary(Data([0x41, 0x00, 0x42])))
        XCTAssertFalse(SearchEngine.isBinary(Data("plain text".utf8)))
        XCTAssertFalse(SearchEngine.isBinary(Data([0xFF, 0xFE, 0x41, 0x00])))
        XCTAssertFalse(SearchEngine.isBinary(Data([0xFE, 0xFF, 0x00, 0x41])))
        XCTAssertFalse(SearchEngine.isBinary(Data(repeating: 0x41, count: 8192) + Data([0x00])))
        XCTAssertTrue(SearchEngine.isBinary(Data(repeating: 0x41, count: 8191) + Data([0x00])))
    }
}

@MainActor
final class ResultActionTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusActions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "FinderPlusActions-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Every suite is a plist in ~/Library/Preferences: without this, each run leaves one behind.
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        removeSuite(named: suiteName)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func finish(_ model: SearchModel) async throws {
        for _ in 0..<300 where model.isSearching || model.isFindingDuplicates {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCSVQuotesOnlyWhatNeedsIt() throws {
        XCTAssertEqual(SearchModel.csvField("plain"), "plain")
        XCTAssertEqual(SearchModel.csvField("a, b"), "\"a, b\"")
        XCTAssertEqual(SearchModel.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")

        let model = SearchModel(defaults: defaults)
        let hit = FileHit(url: URL(filePath: "/tmp/Q3, final.pdf"), name: "Q3, final.pdf", isFolder: false,
                          size: 1234, modified: Date(timeIntervalSince1970: 0), kind: "PDF document")
        let csv = model.resultsCSV([hit])
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}Name,Location,Kind,Size,Date Modified,Date Created,Match\r\n"))
        XCTAssertTrue(csv.contains("\"Q3, final.pdf\",/tmp,PDF document,1234,1970-01-01T00:00:00Z,,\r\n"), csv)
    }

    func testCopyAndMoveNeverOverwrite() throws {
        let source = try write("in/Report.pdf", "x")
        let folder = root.appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write("out/Report.pdf", "already here")

        let copied = SearchModel.perform(.copy, [source], into: folder)
        XCTAssertEqual(copied.done[source]?.lastPathComponent, "Report 2.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "Report.pdf"), encoding: .utf8), "already here")

        let moved = SearchModel.perform(.move, [source], into: folder)
        XCTAssertEqual(moved.done[source]?.lastPathComponent, "Report 3.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    // Copy Rows pasted raw text, so a "=HYPERLINK(…)" name ran as a formula in Excel and a tab in
    // a name shifted every cell after it.
    func testCopyRowsFieldsAreNeutralised() {
        XCTAssertEqual(SearchModel.tsvField("=HYPERLINK(\"x\")"), "'=HYPERLINK(\"x\")")
        XCTAssertEqual(SearchModel.tsvField("a\tb\nc"), "a b c")
        XCTAssertEqual(SearchModel.tsvField("-draft"), "'-draft")
        XCTAssertEqual(SearchModel.tsvField("report.pdf"), "report.pdf")
    }

    // `availableName` split a folder's name at its dot, proposing "v1 2.0" for a clash on "v1.0".
    func testAvailableNameTreatsAFolderNameWhole() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "v1.0"), withIntermediateDirectories: true)
        XCTAssertEqual(SearchModel.availableName(for: "v1.0", in: root, isFolder: true).lastPathComponent, "v1.0 2")
        _ = try write("Report.pdf", "x")
        XCTAssertEqual(SearchModel.availableName(for: "Report.pdf", in: root).lastPathComponent, "Report 2.pdf")
    }

    // A folder and an item inside it both selected (⌘A does this): processed separately, in
    // display order, the item was pulled out of its folder, or its move failed with an alert, or
    // a copy landed twice.
    func testNestedSelectionsTransferAsOneFolder() throws {
        let track = try write("album/track.mp3", "x")
        let folder = track.deletingLastPathComponent()
        let loose = try write("loose.txt", "x")
        XCTAssertEqual(SearchModel.withoutNestedSources([folder, track, loose]), [folder, loose])
        XCTAssertEqual(SearchModel.withoutNestedSources([track]), [track])

        let destination = root.appending(path: "dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outcome = SearchModel.perform(
            .copy, SearchModel.withoutNestedSources([track, folder]), into: destination)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: destination.path).sorted(),
                       ["album", "album/track.mp3"])
    }

    // The containment check resolved the symlink itself, refusing to copy a link into the folder
    // it points at — though the operation copies the link file, which recurses into nothing.
    func testASymlinkToAFolderCopiesIntoThatFolder() throws {
        let folder = root.appending(path: "target")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = root.appending(path: "shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let outcome = SearchModel.perform(.copy, [link], into: folder)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(outcome.done[link]?.lastPathComponent, "shortcut")
        // A real folder into itself is still refused.
        XCTAssertTrue(SearchModel.perform(.copy, [folder], into: folder).failed.first?.contains("into itself") == true)
    }

    // A failed folder copy kept what it had copied: the alert said nothing, and a retry landed
    // beside the remnant as "Album 2".
    func testAFailedFolderCopyLeavesNoPartialCopyBehind() throws {
        let album = try write("Album/one.txt", "x").deletingLastPathComponent()
        let sealed = try write("Album/sealed.txt", "x")
        _ = try write("Album/two.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sealed.path) }
        let destination = root.appending(path: "dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let outcome = SearchModel.perform(.copy, [album], into: destination)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [],
                       "the partial copy must be swept up")
        // And with the sealed file the only failure, the retry can land under the plain name.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sealed.path)
        XCTAssertEqual(SearchModel.perform(.copy, [album], into: destination).done[album]?.lastPathComponent, "Album")
    }

    // A rename mid-walk used to leave ghost rows: hits the enumerator and the pending buffer were
    // already holding arrived under the old path, and `insertSorted` accepted them as new rows
    // nothing on disk answers to (4,252 of 30,000 in the probe that found this).
    func testRenamingAFolderMidWalkLeavesNoGhostRows() async throws {
        let folder = root.appending(path: "proj")
        for sub in 0..<40 {
            let dir = folder.appending(path: "sub\(sub)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0..<400 {
                try Data("x".utf8).write(to: dir.appending(path: "file\(index).txt"))
            }
        }
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "file"
        model.start()
        for _ in 0..<2_000 where model.results.count < 500 && model.isSearching {
            try await Task.sleep(for: .milliseconds(1))
        }
        // The rows carry the walk's canonical paths (/private/var, not /var), and real rename
        // steps are built from rows — so the step must use that spelling too, or nothing matches.
        let walked = URL(filePath: SearchEngine.walkedPath(of: folder), directoryHint: .isDirectory)
        let outcome = SearchModel.performRename(
            [RenameStep(source: walked, target: walked.deletingLastPathComponent().appending(path: "renamed"))])
        XCTAssertEqual(outcome.failed, [])
        model.relocateRows(after: outcome)
        try await finish(model)

        let ghosts = model.results.filter { $0.url.path.contains("/proj/") }
        XCTAssertEqual(ghosts.count, 0, "rows under the old path: \(ghosts.prefix(3).map(\.url.path))")
        XCTAssertTrue(model.results.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
                      "every row must answer to a file on disk")
    }

    // MARK: Mid-walk changes and Find again

    private var walked: String { SearchEngine.walkedPath(of: root) }

    /// A row as the walk reports it, under the walk's /private/var spelling.
    private func row(_ path: String, folder: Bool = false) -> FileHit {
        let url = URL(filePath: walked + "/" + path, directoryHint: folder ? .isDirectory : .notDirectory)
        return FileHit(url: url, name: url.lastPathComponent, isFolder: folder, size: folder ? -1 : 1,
                       modified: .now, kind: folder ? "Folder" : "Text")
    }

    private func walkedURL(_ path: String, folder: Bool = false) -> URL {
        URL(filePath: walked + "/" + path, directoryHint: folder ? .isDirectory : .notDirectory)
    }

    private func paths(_ model: SearchModel) -> [String] {
        model.results.map { String($0.url.path.dropFirst(walked.count + 1)) }.sorted()
    }

    private func searchingModel(_ rows: [FileHit]) -> SearchModel {
        let model = SearchModel(defaults: defaults)
        model.phase = .searching
        model.results = rows
        model.knownIDs = Set(rows.map(\.id))
        return model
    }

    // Folder A renamed to B and B trashed mid-walk: a straggler A/y was checked against the
    // trashed paths before it was moved to B, so it survived as a row for a trashed file.
    func testStragglerOfARenamedThenTrashedFolderIsDropped() throws {
        _ = try write("A/x.txt", "x")
        _ = try write("A/y.txt", "x")
        let model = searchingModel([row("A", folder: true), row("A/x.txt")])
        let outcome = SearchModel.performRename(
            [RenameStep(source: walkedURL("A", folder: true), target: walkedURL("B", folder: true))])
        XCTAssertEqual(outcome.failed, [])
        model.relocateRows(after: outcome)
        // What trash() does for B, bar the real Trash.
        let trashed = walkedURL("B", folder: true)
        try FileManager.default.removeItem(at: trashed)
        model.results.removeAll { $0.url.path.hasPrefix(trashed.path) }
        model.walkTrashed.insert(trashed.path)
        model.knownIDs = Set(model.results.map(\.id))

        model.apply(.hits([row("A/y.txt")]))
        XCTAssertEqual(paths(model), [])
    }

    // Draft 1 and Draft 2 renumbered to Draft 2 and Draft 3: the walk lists the parent afterwards
    // and reports "Draft 2/a draft.txt", which is the real file. Sent on to Draft 3 it became a
    // ghost that survived the walk.
    func testHitsAtReusedPathsAreNotRemappedAfterARenumbering() throws {
        _ = try write("Draft 1/a draft.txt", "x")
        _ = try write("Draft 2/b draft.txt", "x")
        let model = searchingModel([
            row("Draft 1", folder: true), row("Draft 1/a draft.txt"),
            row("Draft 2", folder: true), row("Draft 2/b draft.txt"),
        ])
        let outcome = SearchModel.performRename([
            RenameStep(source: walkedURL("Draft 2", folder: true), target: walkedURL("Draft 3", folder: true)),
            RenameStep(source: walkedURL("Draft 1", folder: true), target: walkedURL("Draft 2", folder: true)),
        ])
        XCTAssertEqual(outcome.failed, [])
        model.relocateRows(after: outcome)
        model.apply(.hits([
            row("Draft 2", folder: true), row("Draft 2/a draft.txt"),
            row("Draft 3", folder: true), row("Draft 3/b draft.txt"),
        ]))
        XCTAssertEqual(paths(model), ["Draft 2", "Draft 2/a draft.txt", "Draft 3", "Draft 3/b draft.txt"])
        XCTAssertTrue(model.results.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    // Report.pdf trashed and a new one created in its place: the walk reports the new file at the
    // trashed path, and it was dropped with the old one.
    func testHitAtATrashedPathIsKeptWhenAFileIsThereAgain() throws {
        let old = try write("Report.pdf", "old")
        let model = searchingModel([row("Report.pdf")])
        try FileManager.default.removeItem(at: old)
        model.results = []
        model.knownIDs = []
        model.walkTrashed.insert(walkedURL("Report.pdf").path)
        _ = try write("Report.pdf", "new")
        model.apply(.hits([row("Report.pdf")]))
        XCTAssertEqual(paths(model), ["Report.pdf"])
    }

    // A to B, then B/sub to B/sub2: a straggler found under A/sub arrived as B/sub/g.txt, where
    // nothing is.
    func testStragglerFollowsARenameInsideAnEarlierRenamesNewPath() throws {
        _ = try write("A/sub/f.txt", "x")
        _ = try write("A/sub/g.txt", "x")
        let model = searchingModel([row("A", folder: true), row("A/sub", folder: true), row("A/sub/f.txt")])
        let first = SearchModel.performRename(
            [RenameStep(source: walkedURL("A", folder: true), target: walkedURL("B", folder: true))])
        model.relocateRows(after: first)
        let second = SearchModel.performRename(
            [RenameStep(source: walkedURL("B/sub", folder: true), target: walkedURL("B/sub2", folder: true))])
        XCTAssertEqual(second.failed, [])
        model.relocateRows(after: second)
        model.apply(.hits([row("A/sub/g.txt")]))
        XCTAssertEqual(paths(model), ["B", "B/sub2", "B/sub2/f.txt", "B/sub2/g.txt"])
    }

    // Find again keeps the rows on screen through an off-main check, and the user can rename or
    // trash during it; adopting the snapshot then put the old names and trashed rows back.
    func testFindAgainAdoptsRowsWithChangesMadeWhileItChecked() throws {
        _ = try write("A/x.txt", "x")
        _ = try write("C/z.txt", "x")
        let kept = [row("A", folder: true), row("A/x.txt"), row("C", folder: true), row("C/z.txt")]
        let model = searchingModel([])
        let outcome = SearchModel.performRename(
            [RenameStep(source: walkedURL("A", folder: true), target: walkedURL("B", folder: true))])
        model.relocateRows(after: outcome)
        let trashed = walkedURL("C", folder: true)
        try FileManager.default.removeItem(at: trashed)
        model.walkTrashed.insert(trashed.path)

        let run = SearchModel.Run(roots: [walked], options: model.options, limits: model.settings.limits)
        model.adopt(kept, for: run, at: .folder(root.path))
        XCTAssertEqual(paths(model), ["B", "B/x.txt"])
        XCTAssertTrue(model.results.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    // Stopped before the rows are adopted, the old rows are still on screen and the subtitle read
    // "N matches in <the new place>".
    func testLocationLabelChangesWithTheRowsNotWithTheClick() async throws {
        _ = try write("note.txt", "x")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "note"
        model.start()
        XCTAssertNil(model.searchedLocation)
        try await finish(model)
        XCTAssertEqual(model.searchedLocation, .folder(root.path))
    }

    // MARK: Trash, Copy To and Move To

    // The confirmation alert displayed for real under `swift test` and held the suite until
    // someone clicked it. Gated, the call returns and nothing is trashed.
    func testTrashDoesNotShowItsAlertUnderTests() async throws {
        let file = try write("keep.txt", "x")
        let model = SearchModel(defaults: defaults)
        XCTAssertTrue(model.settings.confirmTrash)
        model.results = [row("keep.txt")]
        await model.trash([model.results[0].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // Folder and child both selected: only the folder is tried, so a refused folder left the child
    // untried. The child is asked for again when its folder was refused, and only then.
    func testItemsCoveredByARefusedFolderAreTriedAgain() {
        let folder = URL(filePath: "/x/album", directoryHint: .isDirectory)
        let track = URL(filePath: "/x/album/disc/track.mp3")
        let disc = URL(filePath: "/x/album/disc", directoryHint: .isDirectory)
        let other = URL(filePath: "/x/loose.txt")
        let selected = [folder, track, disc, other]
        XCTAssertEqual(SearchModel.coveredByRefused(selected, refused: [folder]), [disc])
        XCTAssertEqual(SearchModel.coveredByRefused(selected, refused: [other]), [])
        XCTAssertEqual(SearchModel.coveredByRefused(selected, refused: []), [])
    }

    // `fileExists` follows links, so a dangling symlink in the destination read as a free name:
    // the copy failed with "already exists" and the cleanup after it deleted the user's link.
    func testADanglingSymlinkAtTheTargetCountsAsTaken() throws {
        let source = try write("src/a.txt", "x")
        let destination = root.appending(path: "dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = destination.appending(path: "a.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Gone/a.txt")

        let copied = SearchModel.perform(.copy, [source], into: destination)
        XCTAssertEqual(copied.failed, [])
        XCTAssertEqual(copied.done[source]?.lastPathComponent, "a 2.txt")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link was deleted")

        let moved = SearchModel.perform(.move, [source], into: destination)
        XCTAssertEqual(moved.failed, [])
        XCTAssertEqual(moved.done[source]?.lastPathComponent, "a 3.txt")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testAlreadyExistsErrorsAreRecognised() {
        XCTAssertTrue(SearchModel.isAlreadyExists(CocoaError(.fileWriteFileExists)))
        XCTAssertTrue(SearchModel.isAlreadyExists(NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))))
        XCTAssertTrue(SearchModel.isAlreadyExists(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)),
            ])))
        XCTAssertFalse(SearchModel.isAlreadyExists(CocoaError(.fileWriteNoPermission)))
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // A move across volumes copies and then deletes. With a read-only subfolder the delete fails
    // halfway: the copy is whole and the original is part gone, but the move was reported as not
    // done and blamed on the destination, and the row stayed at the original.
    func testACrossVolumeMoveThatCannotRemoveTheOriginalIsReportedAsCopied() throws {
        let image = root.appending(path: "volume.sparseimage")
        let mount = root.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try run("/usr/bin/hdiutil", ["create", "-size", "40m", "-fs", "APFS", "-type", "SPARSE",
                                           "-volname", "FPTest", root.appending(path: "volume").path]),
              try run("/usr/bin/hdiutil", ["attach", "-mountpoint", mount.path, "-nobrowse", image.path])
        else { throw XCTSkip("Could not create a second volume to move across") }
        addTeardownBlock { _ = try? self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        _ = try write("Album/one.txt", "x")
        let sealed = try write("Album/sealed/two.txt", "x").deletingLastPathComponent()
        let album = root.appending(path: "Album")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sealed.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path) }

        let outcome = SearchModel.perform(.move, [album], into: mount)
        XCTAssertEqual(outcome.done[album]?.path, mount.appending(path: "Album").path)
        XCTAssertEqual(outcome.failed.count, 1, "\(outcome.failed)")
        XCTAssertTrue(outcome.failed[0].contains("Copied to"), outcome.failed[0])
        XCTAssertFalse(outcome.deniedByPermissions)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "Album/sealed/two.txt").path))
        // Nothing is made on a retry beside the copy: it is the caller's row that follows it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount.appending(path: "Album 2").path))
    }

    // MARK: Rename

    // The holding name a file is parked under shows to a walk that lists the folder meanwhile.
    // Rows it produced follow the file to where it ended up, and so do hits that arrive later.
    func testRowsUnderAHoldingNameFollowTheFile() async throws {
        _ = try write("one.txt", "x")
        let holding = walkedURL(".FinderPlus-rename-tok-0")
        let target = walkedURL("two.txt")
        let model = searchingModel([row("one.txt"), FileHit(
            url: holding, name: holding.lastPathComponent, isFolder: false, size: 1, modified: .now, kind: "Text")])
        await model.rename([RenameStep(source: walkedURL("one.txt"), target: target)], token: "tok")
        XCTAssertEqual(paths(model), ["two.txt"])
        model.apply(.hits([FileHit(
            url: holding, name: holding.lastPathComponent, isFolder: false, size: 1, modified: .now, kind: "Text")]))
        XCTAssertEqual(paths(model), ["two.txt"])
    }

    func testDuplicatesAreGroupedAndTheFullListComesBack() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        _ = try write("b/photo copy.jpg", "same bytes")
        _ = try write("c/other.jpg", "diff bytes")   // same size, different contents
        _ = try write("d/small.jpg", "tiny")

        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "jpg"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.count, 4)

        model.findDuplicates()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name).sorted(), ["photo copy.jpg", "photo.jpg"])
        XCTAssertEqual(Set(model.results.compactMap { model.duplicateSets[$0.id] }), [1])
        XCTAssertEqual(model.duplicateSummary.reclaimable, 10)

        model.leaveDuplicates()
        XCTAssertEqual(model.results.count, 4)
        XCTAssertFalse(model.showsDuplicates)
    }

    // Moving a folder used to rewrite only the folder's own row: rows for the files inside it
    // kept their old paths, resolving to whatever later took those names.
    func testMovingAFolderCarriesItsChildRowsAlong() async throws {
        _ = try write("pack/paper.txt", "x")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "pa"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name).sorted(), ["pack", "paper.txt"])

        let folder = try XCTUnwrap(model.results.first { $0.isFolder })
        model.selection = [folder.id]
        let destination = root.appending(path: "out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outcome = SearchModel.perform(.move, [folder.url], into: destination)
        XCTAssertEqual(outcome.failed, [])
        model.relocateRows(after: outcome)

        let child = try XCTUnwrap(model.results.first { $0.name == "paper.txt" })
        XCTAssertEqual(child.url.path, destination.appending(path: "pack/paper.txt").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.url.path))
        // The moved folder stays selected under its new ID, the way a renamed row does.
        XCTAssertEqual(model.selection, [destination.appending(path: "pack").path])
    }

    func testMovingADuplicateKeepsItsSetNumber() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        _ = try write("b/photo copy.jpg", "same bytes")

        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "jpg"
        model.start()
        try await finish(model)
        model.findDuplicates()
        try await finish(model)
        XCTAssertEqual(model.results.count, 2)

        let victim = try XCTUnwrap(model.results.first { $0.name == "photo.jpg" })
        let destination = root.appending(path: "c")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outcome = SearchModel.perform(.move, [victim.url], into: destination)
        XCTAssertEqual(outcome.failed, [])
        model.relocateRows(after: outcome)

        let moved = try XCTUnwrap(model.results.first { $0.url.path.hasPrefix(destination.path) })
        XCTAssertEqual(model.duplicateSets[moved.id], 1)
        XCTAssertEqual(model.duplicateSummary.files, 2)
    }

    func testRenamingADuplicateToAFreshNameKeepsItsSetNumber() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        _ = try write("b/photo copy.jpg", "same bytes")

        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "jpg"
        model.start()
        try await finish(model)
        model.findDuplicates()
        try await finish(model)
        XCTAssertEqual(model.results.count, 2)

        let victim = try XCTUnwrap(model.results.first { $0.name == "photo.jpg" })
        let target = victim.url.deletingLastPathComponent().appending(path: "fresh.jpg")
        await model.rename([RenameStep(source: victim.url, target: target)])

        let renamed = try XCTUnwrap(model.results.first { $0.name == "fresh.jpg" })
        XCTAssertEqual(model.duplicateSets[renamed.id], 1)
        XCTAssertEqual(model.duplicateSummary.sets, 1)
        XCTAssertEqual(model.duplicateSummary.files, 2)
    }

    func testAFailedSearchClearsTheDuplicatesView() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        _ = try write("b/photo copy.jpg", "same bytes")

        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "jpg"
        model.start()
        try await finish(model)
        model.findDuplicates()
        try await finish(model)
        XCTAssertTrue(model.showsDuplicates)

        // An unclosed regex group fails in start() before anything is walked.
        model.options.mode = .regex
        model.query = "(unclosed"
        model.start()
        try await finish(model)
        guard case .failed = model.phase else {
            return XCTFail("the search should have failed, not \(model.phase)")
        }
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.showsDuplicates, "a failed search must not leave the duplicates bar up")
        model.leaveDuplicates()
        XCTAssertTrue(model.results.isEmpty, "nothing to restore after a failed search")
    }

    func testAFileHandedToTheServiceSearchesItsFolder() throws {
        let file = try write("Projects/plan.txt", "x")
        let model = SearchModel(defaults: defaults)
        model.useFolders([file])
        XCTAssertEqual(model.location, .folder(file.deletingLastPathComponent().standardizedFileURL.path))
    }

    func testPreviewFindsEveryMatch() throws {
        let matcher = try QueryMatcher(query: "cat", options: SearchOptions(), anchorsWildcards: false)
        let text = "cat, then concatenate, then Cat"
        let found = matcher.ranges(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["cat", "cat", "Cat"])
    }

    // A kept row used to show the last run's size until something else replaced it.
    func testFindAgainShowsTheFilesNewSize() async throws {
        let file = try write("grow.txt", "12345")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "grow"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.size), [5])
        let id = try XCTUnwrap(model.results.first?.id)
        model.selection = [id]

        try String(repeating: "x", count: 5000).write(to: file, atomically: true, encoding: .utf8)
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name), ["grow.txt"])
        XCTAssertEqual(model.results.map(\.size), [5000])
        // Still selected, so the row was kept rather than dropped and found again — which needs
        // the roots compared canonically, as this temporary folder is under /var.
        XCTAssertEqual(model.selection, [id])
    }

    func testFindAgainDropsAKeptRowThatNoLongerPassesTheSizeFilter() async throws {
        let file = try write("grow.txt", "12345")
        _ = try write("grow-small.txt", "12345")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "grow"
        model.options.size = .under1MB
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name).sorted(), ["grow-small.txt", "grow.txt"])

        try String(repeating: "x", count: 1_000_001).write(to: file, atomically: true, encoding: .utf8)
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name), ["grow-small.txt"])
    }

    func testStopEndsFindDuplicates() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        _ = try write("b/photo copy.jpg", "same bytes")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "jpg"
        model.start()
        try await finish(model)
        XCTAssertEqual(model.results.count, 2)

        model.findDuplicates()
        XCTAssertTrue(model.isFindingDuplicates)
        model.stop()
        XCTAssertFalse(model.isFindingDuplicates)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.isFindingDuplicates)
        XCTAssertFalse(model.showsDuplicates, "a stopped hash must not bring up the duplicates view")
        XCTAssertEqual(model.results.count, 2)
    }

    // Run again from the duplicates view, a search that found none restored the full list.
    func testFindingNoDuplicatesAgainKeepsTheDuplicatesView() async throws {
        _ = try write("a/photo.jpg", "same bytes")
        let copy = try write("b/photo copy.jpg", "same bytes")
        _ = try write("c/other.png", "x")
        let model = SearchModel(defaults: defaults)
        model.locationID = root.path
        model.query = "photo"
        model.start()
        try await finish(model)
        model.findDuplicates()
        try await finish(model)
        XCTAssertEqual(model.results.count, 2)

        try "diff bytes".write(to: copy, atomically: true, encoding: .utf8)
        // The "No duplicates" alert is skipped under XCTest: the modal panel really displays on
        // whatever screen runs the tests, and the suite would sit behind it until someone clicked.
        model.findDuplicates()
        try await finish(model)
        XCTAssertTrue(model.showsDuplicates)
        XCTAssertEqual(model.results.count, 2)
        model.leaveDuplicates()
        XCTAssertEqual(model.results.count, 2)
    }

    func testMovingAFileIntoItsOwnFolderLeavesItAlone() throws {
        let file = try write("in/Report.pdf", "x")
        let outcome = SearchModel.perform(.move, [file], into: file.deletingLastPathComponent())
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(outcome.done[file], file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["Report.pdf"])
    }

    func testDuplicateFinderCountsFilesItCouldNotRead() throws {
        let one = try write("one.txt", "same bytes")
        let two = try write("two.txt", "same bytes")
        func candidate(_ url: URL) -> DuplicateFinder.Candidate {
            DuplicateFinder.Candidate(id: url.path, url: url, size: 10)
        }

        let readable = DuplicateFinder.sets(in: [candidate(one), candidate(two)])
        XCTAssertEqual(readable.sets.map { Set($0) }, [[one.path, two.path]])
        XCTAssertEqual(readable.unread, 0)

        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: two.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: two.path) }
        let unreadable = DuplicateFinder.sets(in: [candidate(one), candidate(two)])
        XCTAssertEqual(unreadable.sets, [])
        XCTAssertEqual(unreadable.unread, 1)
    }

    func testDigestNeedsTheFilesRealSize() throws {
        let file = try write("digest.txt", "hello")
        let digest = try XCTUnwrap(DuplicateFinder.digest(of: file, limit: nil, size: 5))
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotNil(digest.wholeMatch(of: /[0-9a-f]{64}/))
        XCTAssertNil(DuplicateFinder.digest(of: file, limit: nil, size: 6))
    }
}

final class BatchRenameTests: XCTestCase {
    /// A local-calendar noon, so the date the recipe stamps cannot straddle midnight in any zone.
    private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!

    func testReplaceTextWorksOnTheWholeName() {
        var recipe = BatchRename.Recipe()
        recipe.action = .replaceText
        recipe.find = "IMG_"
        recipe.replacement = "Holiday "
        XCTAssertEqual(recipe.newName(for: "IMG_0042.jpg", at: 0), "Holiday 0042.jpg")
        recipe.find = ".jpg"
        recipe.replacement = ".jpeg"
        XCTAssertEqual(recipe.newName(for: "IMG_0042.jpg", at: 0), "IMG_0042.jpeg")
        recipe.find = ""
        XCTAssertEqual(recipe.newName(for: "IMG_0042.jpg", at: 0), "IMG_0042.jpg")
    }

    func testSequenceNumbersFromTheStartAndKeepsExtensions() {
        var recipe = BatchRename.Recipe()
        recipe.action = .sequence
        recipe.base = "Holiday"
        recipe.start = 10
        XCTAssertEqual(recipe.newName(for: "IMG_0042.jpg", at: 0), "Holiday 10.jpg")
        XCTAssertEqual(recipe.newName(for: "IMG_0043.HEIC", at: 1), "Holiday 11.HEIC")
        recipe.base = "  "
        XCTAssertEqual(recipe.newName(for: "IMG_0042.jpg", at: 0), "IMG_0042 10.jpg")
    }

    func testChangeCaseKeepsTheExtension() {
        var recipe = BatchRename.Recipe()
        recipe.action = .changeCase
        recipe.caseStyle = .uppercase
        XCTAssertEqual(recipe.newName(for: "report draft.txt", at: 0), "REPORT DRAFT.txt")
        recipe.caseStyle = .capitalized
        XCTAssertEqual(recipe.newName(for: "report draft.txt", at: 0), "Report Draft.txt")
        recipe.caseStyle = .lowercase
        XCTAssertEqual(recipe.newName(for: "README", at: 0), "readme")
    }

    func testAddDateUsesTheLocalDay() {
        var recipe = BatchRename.Recipe()
        recipe.action = .addDate
        recipe.datePosition = .before
        XCTAssertEqual(recipe.newName(for: "report.txt", at: 0, on: noon), "2026-09-27 report.txt")
        recipe.datePosition = .after
        XCTAssertEqual(recipe.newName(for: "report.txt", at: 0, on: noon), "report 2026-09-27.txt")
    }

    /// A temp folder that goes at the end of the test, locked files included.
    private func makeFolder() throws -> URL {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "FinderPlusPlan-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            let entries = manager.enumerator(at: folder, includingPropertiesForKeys: nil)
            for case let url as URL in entries?.allObjects ?? [] {
                try? manager.setAttributes([.immutable: false], ofItemAtPath: url.path)
            }
            try? manager.removeItem(at: folder)
        }
        return folder
    }

    private func hit(_ folder: URL, _ path: String, isFolder: Bool = false) throws -> FileHit {
        let url = folder.appending(path: path)
        if isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        return FileHit(url: url, name: url.lastPathComponent, isFolder: isFolder, size: isFolder ? -1 : 1,
                       modified: .now, kind: isFolder ? "Folder" : "Text")
    }

    private func replacing(_ find: String, with replacement: String) -> BatchRename.Recipe {
        var recipe = BatchRename.Recipe()
        recipe.action = .replaceText
        recipe.find = find
        recipe.replacement = replacement
        return recipe
    }

    func testPlanFlagsTwoRowsThatWouldGetTheSameNameEvenIfOnlyCaseDiffers() throws {
        let folder = try makeFolder()
        let hits = [try hit(folder, "Foo1.txt"), try hit(folder, "foo11.txt")]
        let plan = BatchRename.plan(hits, recipe: replacing("1", with: ""))
        XCTAssertEqual(plan.map(\.name), ["Foo.txt", "foo.txt"])
        XCTAssertEqual(plan.map(\.problem), Array(repeating: "Two items would get this name", count: 2))
    }

    func testPlanFlagsAnExistingFileOutsideTheBatch() throws {
        let folder = try makeFolder()
        _ = try hit(folder, "existing.txt")
        let plan = BatchRename.plan([try hit(folder, "old.txt")], recipe: replacing("old", with: "existing"))
        XCTAssertEqual(plan.map(\.problem), ["A file with this name already exists"])
    }

    func testPlanFlagsARowInsideAFolderTheBatchRenames() throws {
        let folder = try makeFolder()
        let dir = try hit(folder, "dir", isFolder: true)
        let inside = try hit(folder, "dir/x.txt")
        var recipe = BatchRename.Recipe()
        recipe.action = .changeCase
        recipe.caseStyle = .uppercase
        let plan = BatchRename.plan([dir, inside], recipe: recipe)
        XCTAssertEqual(plan.map(\.name), ["DIR", "X.txt"])
        XCTAssertNil(plan[0].problem)
        XCTAssertEqual(plan[1].problem, "Inside a folder that is also being renamed")
    }

    func testPlanFlagsALockedFile() throws {
        let folder = try makeFolder()
        let locked = try hit(folder, "lock.txt")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.url.path)
        var recipe = BatchRename.Recipe()
        recipe.action = .changeCase
        recipe.caseStyle = .uppercase
        XCTAssertEqual(BatchRename.plan([locked], recipe: recipe).map(\.problem), ["File is locked"])
    }

    // A leading dot is refused because it would hide the file, which a dotfile already is.
    func testPlanAllowsRenamingAnAlreadyHiddenFile() throws {
        let folder = try makeFolder()
        let env = try hit(folder, ".env.local")
        let plan = BatchRename.plan([env], recipe: replacing("local", with: "prod"))
        XCTAssertEqual(plan.map(\.name), [".env.prod"])
        XCTAssertEqual(plan.map(\.problem), [nil])
        let visible = try hit(folder, "IMG.jpg")
        XCTAssertNotNil(BatchRename.plan([visible], recipe: replacing("IMG", with: "")).first?.problem)
    }

    func testPlanLeavesAnUnchangedNameAloneAndAllowsASwap() throws {
        let folder = try makeFolder()
        let same = try hit(folder, "same.txt")
        var lower = BatchRename.Recipe()
        lower.action = .changeCase
        lower.caseStyle = .lowercase
        let unchanged = try XCTUnwrap(BatchRename.plan([same], recipe: lower).first)
        XCTAssertNil(unchanged.problem)
        XCTAssertFalse(unchanged.changes)

        // Numbered in list order, "F 2" becomes "F 1" and "F 1" becomes "F 2".
        var recipe = BatchRename.Recipe()
        recipe.action = .sequence
        recipe.base = "F"
        recipe.start = 1
        let swapped = BatchRename.plan([try hit(folder, "F 2.txt"), try hit(folder, "F 1.txt")], recipe: recipe)
        XCTAssertEqual(swapped.map(\.name), ["F 1.txt", "F 2.txt"])
        XCTAssertEqual(swapped.map(\.problem), [nil, nil])
        XCTAssertEqual(swapped.map(\.changes), [true, true])
    }

    func testProblemsCatchUnusableNames() {
        XCTAssertNotNil(BatchRename.problem(with: ""))
        // Replace Text can empty the stem: "IMG.jpg" minus "IMG" plans ".jpg", a hidden file.
        XCTAssertNotNil(BatchRename.problem(with: ".jpg"))
        XCTAssertNotNil(BatchRename.problem(with: "a/b"))
        XCTAssertNotNil(BatchRename.problem(with: "a:b"))
        XCTAssertNotNil(BatchRename.problem(with: ".."))
        XCTAssertNotNil(BatchRename.problem(with: String(repeating: "é", count: 200)))
        XCTAssertNil(BatchRename.problem(with: "Report 2.pdf"))
    }

    func testPerformRenameSwapsNamesWithoutColliding() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinderPlusRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appending(path: "1.txt")
        let two = folder.appending(path: "2.txt")
        try "first".write(to: one, atomically: true, encoding: .utf8)
        try "second".write(to: two, atomically: true, encoding: .utf8)

        let outcome = SearchModel.performRename([
            RenameStep(source: one, target: two),
            RenameStep(source: two, target: one),
        ])
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "first")
        // Nothing left parked under a holding name.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".FinderPlus-rename-") }
        XCTAssertEqual(leftovers, [])
    }

    // A locked file used to strand another file's content under a hidden holding name, because
    // the rollback was a silent `try?` onto a name an earlier step had already taken.
    func testAFailedRenameRollsTheWholeBatchBack() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "FinderPlusRename-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let one = folder.appending(path: "Photo 1.jpg")
        let two = folder.appending(path: "Photo 2.jpg")
        let three = folder.appending(path: "Photo 3.jpg")
        try "first".write(to: one, atomically: true, encoding: .utf8)
        try "second".write(to: two, atomically: true, encoding: .utf8)
        try "third".write(to: three, atomically: true, encoding: .utf8)
        try manager.setAttributes([.immutable: true], ofItemAtPath: three.path)
        defer {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: three.path)
            try? manager.removeItem(at: folder)
        }

        // Renumbering 1, 2, 3 up to 2, 3, 4: the locked file blocks its own move, and the whole
        // batch must come back rather than leave "Photo 2" both taken and parked.
        let outcome = SearchModel.performRename([
            RenameStep(source: one, target: two),
            RenameStep(source: two, target: three),
            RenameStep(source: three, target: folder.appending(path: "Photo 4.jpg")),
        ])
        XCTAssertTrue(outcome.done.isEmpty)
        XCTAssertFalse(outcome.failed.isEmpty)
        // Locked is not a Full Disk Access problem: granting access would not unlock the file.
        XCTAssertFalse(outcome.deniedByPermissions)
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: three, encoding: .utf8), "third")
        let leftovers = try manager.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".FinderPlus-rename-") }
        XCTAssertEqual(leftovers, [])
    }

    // The test above fails while parking, so nothing has landed yet. A failure while landing is
    // the harder unwind: a file already under its new name must go back to its holding name before
    // anything is unparked, and a file that sat at a target name all along must not be disturbed.
    func testAFailureWhileLandingUndoesTheFilesAlreadyRenamed() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "FinderPlusRename-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let one = folder.appending(path: "1.txt")
        let two = folder.appending(path: "2.txt")
        let a = folder.appending(path: "A.txt")
        let b = folder.appending(path: "B.txt")
        try "first".write(to: one, atomically: true, encoding: .utf8)
        try "second".write(to: two, atomically: true, encoding: .utf8)
        try "interloper".write(to: b, atomically: true, encoding: .utf8)

        // Both park, "1" lands as "A", then "2" cannot land because "B.txt" is taken.
        let outcome = SearchModel.performRename([
            RenameStep(source: one, target: a),
            RenameStep(source: two, target: b),
        ])
        XCTAssertTrue(outcome.done.isEmpty)
        XCTAssertFalse(outcome.failed.isEmpty)
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "second")
        XCTAssertFalse(manager.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "interloper")
        let leftovers = try manager.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".FinderPlus-rename-") }
        XCTAssertEqual(leftovers, [])
        // Only a file left stranded is ever named by its holding name; here none was.
        XCTAssertFalse(outcome.failed.contains { $0.contains(".FinderPlus-rename-") }, "\(outcome.failed)")
    }
}

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "FinderPlusPreferences-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Every suite is a plist in ~/Library/Preferences: without this, each run leaves one behind.
    override func tearDown() async throws {
        removeSuite(named: suiteName)
    }

    func testWindowsShareSettingsAndRecents() {
        let shared = Preferences(defaults: defaults)
        let first = SearchModel(defaults: defaults, preferences: shared)
        let second = SearchModel(defaults: defaults, preferences: shared)

        first.settings.showFullPaths = true
        XCTAssertTrue(second.settings.showFullPaths)

        shared.remember("invoice")
        XCTAssertEqual(second.recentQueries, ["invoice"])
        second.clearRecents()
        XCTAssertEqual(first.recentQueries, [])

        first.customLocations = [.folder("/tmp")]
        XCTAssertEqual(second.customLocations, [.folder("/tmp")])
    }

    func testPreferencesPersistAcrossLaunches() {
        let before = Preferences(defaults: defaults)
        before.settings.confirmTrash = false
        before.remember("report")
        let after = Preferences(defaults: defaults)
        XCTAssertFalse(after.settings.confirmTrash)
        XCTAssertEqual(after.recentQueries, ["report"])
    }
}

final class IntentSearchTests: XCTestCase {
    func testFindsByNameAndRespectsTheLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinderPlusIntent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.pdf", "b.pdf", "c.txt"] {
            try "x".write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }

        var options = SearchOptions()
        options.mode = .wildcards
        let all = try await IntentSearch.hits(query: "*.pdf", root: folder, options: options, limit: 0)
        XCTAssertEqual(Set(all.map(\.name)), ["a.pdf", "b.pdf"])

        let capped = try await IntentSearch.hits(query: "*.pdf", root: folder, options: options, limit: 1)
        XCTAssertEqual(capped.count, 1)

        await XCTAssertThrowsErrorAsync(
            try await IntentSearch.hits(
                query: "*", root: folder.appending(path: "missing"), options: options, limit: 0))
    }
}

/// XCTAssertThrowsError has no async form.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
