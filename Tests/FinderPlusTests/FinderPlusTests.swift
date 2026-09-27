import XCTest
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

    private func search(_ query: String, _ configure: (inout SearchOptions) -> Void = { _ in }) throws -> [FileHit] {
        var options = SearchOptions()
        configure(&options)
        let request = try SearchRequest(roots: [root], query: query, options: options)
        var hits: [FileHit] = []
        SearchEngine.walk(request) { event in
            if case .hits(let batch) = event { hits += batch }
        }
        return hits.sorted { $0.name < $1.name }
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
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusModel-\(UUID().uuidString)")
        for name in ["invoice-march.txt", "invoice-april.txt", "inventory.csv", "notes.md"] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "x".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        defaults = UserDefaults(suiteName: "FinderPlusTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
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
        // Before the new walk reports anything, the table has already narrowed rather than emptied.
        XCTAssertEqual(model.results.map(\.name), ["invoice-april.txt", "invoice-march.txt"])
        try await finish(model)
        XCTAssertEqual(model.results.map(\.name), ["invoice-april.txt", "invoice-march.txt"])
    }
}
