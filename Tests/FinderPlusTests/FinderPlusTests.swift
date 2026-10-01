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
        XCTAssertEqual(QueryMatcher.wildcardPattern("*.pdf", anchored: true), "^.*\\.pdf$")

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
    private func makeZip(_ name: String, _ members: [String: String]) throws -> URL {
        let staging = root.appending(path: "staging-\(name)")
        for (path, text) in members {
            let url = staging.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-qr", root.appending(path: name).path, "."]
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

        let pptx = try makeZip("deck.pptx", ["ppt/slides/slide1.xml": "<p:sld><a:t>Launch</a:t><a:t>plan</a:t></p:sld>"])
        XCTAssertTrue(try XCTUnwrap(SearchEngine.contentText(of: pptx, size: 1)).contains("Launch plan"))

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
        // The "No duplicates" alert is modal; the test host has no window to show it in, so it
        // returns at once.
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
