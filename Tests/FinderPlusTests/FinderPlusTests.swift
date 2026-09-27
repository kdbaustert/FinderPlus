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
    }

    // Audit 3: Stop now reaches the walk and its content workers.
    func testAStoppedWalkReportsNothing() throws {
        for index in 0..<50 { _ = try write("file\(index).txt", "needle") }
        let hits = try walk("needle", { $0.searchNames = false; $0.searchContents = true }, isStopped: { true })
        XCTAssertEqual(hits, [])
    }

    // Audit 10: a query of exclusions alone now says why instead of clearing the results.
    func testExclusionsOnlyQueryExplainsItself() {
        XCTAssertThrowsError(try QueryMatcher(query: "-draft", options: SearchOptions())) { error in
            guard case QueryError.onlyExclusions = error else { return XCTFail("\(error)") }
        }
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
}

@MainActor
final class AuditModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FinderPlusAuditModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["invoice-march.txt", "notes.md", "notes-old.md"] {
            try "x".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        defaults = UserDefaults(suiteName: "FinderPlusAudit-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
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
