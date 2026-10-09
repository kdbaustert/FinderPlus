import AppKit
import CryptoKit
import os
import PDFKit
import UniformTypeIdentifiers

struct FileHit: Identifiable, Hashable, Sendable {
    /// The file — or, for an entry listed from a zip archive, the archive that holds it.
    let url: URL
    /// The entry's path inside the archive at `url`; nil for an ordinary file.
    let archiveEntry: String?
    let name: String
    let isFolder: Bool
    /// -1 for folders, packages and archive entries, whose size the walk does not know.
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String
    var snippet: Snippet?

    init(
        url: URL, archiveEntry: String? = nil, name: String, isFolder: Bool, size: Int64,
        modified: Date, created: Date = .distantPast, kind: String, snippet: Snippet? = nil
    ) {
        self.url = url
        self.archiveEntry = archiveEntry
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.created = created
        self.kind = kind
        self.snippet = snippet
        // Stored, not computed: the selection lookup reads every row's ID and the Location sort
        // reads `parentPath` per comparison, and each read built a new string. For an ordinary
        // file the ID and full path share one string.
        let path = url.path
        id = archiveEntry.map { path + "\u{0}" + $0 } ?? path
        fullPath = archiveEntry.map { path + "/" + $0 } ?? path
        parentPath = (fullPath as NSString).deletingLastPathComponent
    }

    /// Unique per row: every entry of an archive shares the archive's URL.
    let id: String
    var isArchiveEntry: Bool { archiveEntry != nil }
    var snippetText: String { snippet?.text ?? "" }

    /// The file's path; for an archive entry, the archive's path followed by the entry's.
    let fullPath: String

    let parentPath: String

    var displayParent: String {
        let home = NSHomeDirectory()
        let parent = parentPath
        // A whole path component only: `/Users/kennyb` must not become `~b`.
        guard parent == home || parent.hasPrefix(home + "/") else { return parent }
        return "~" + parent.dropFirst(home.count)
    }

    var sizeText: String {
        size < 0 ? "—" : size.formatted(.byteCount(style: .file))
    }
}

enum SearchEvent: Sendable {
    case hits([FileHit])
    /// `timedOut`: texts a regular expression gave up on, so the results may be missing files.
    case progress(scanned: Int, current: String, unreadable: Int, timedOut: Int)
    /// The match limit from Settings was reached and the walk stopped early.
    case limitReached
}

/// The parts of Settings that change what a search does. The defaults are the behaviour before
/// Settings existed.
struct SearchLimits: Equatable, Sendable {
    var maxContentBytes = 50 * 1024 * 1024
    /// 0 means no limit.
    var maxResults = 0
    /// Folder names skipped wherever they appear, compared case-insensitively.
    var skippedFolderNames: Set<String> = []
}

struct SearchRequest: Sendable {
    let roots: [URL]
    /// For names and tags, where a wildcard pattern like `*.pdf` means the whole string.
    let nameMatcher: QueryMatcher
    /// For contents and comments, where it means a fragment.
    let textMatcher: QueryMatcher
    let options: SearchOptions
    let limits: SearchLimits

    init(
        roots: [URL], query: String, options: SearchOptions, limits: SearchLimits = SearchLimits(),
        matchBudget: Duration = .seconds(2)
    ) throws {
        self.roots = roots
        self.options = options
        self.limits = SearchLimits(
            maxContentBytes: limits.maxContentBytes,
            maxResults: limits.maxResults,
            skippedFolderNames: Set(limits.skippedFolderNames.map { $0.lowercased() }))
        nameMatcher = try QueryMatcher(query: query, options: options, anchorsWildcards: true, timeBudget: matchBudget)
        textMatcher = try QueryMatcher(query: query, options: options, anchorsWildcards: false, timeBudget: matchBudget)
    }
}

/// A live, index-free walk of the file system, like EasyFind's: slower than Spotlight, but it sees
/// hidden, system and never-indexed files.
enum SearchEngine {

    /// TypeScript's extensions, which macOS maps to MPEG-2 types: `.ts` a transport stream,
    /// `.mts` and `.cts` AVCHD. Either meaning can be true of any one file, so these are shown
    /// under a neutral kind, and kept out of kind exclusion unless the content is a transport
    /// stream (see `isMPEGTransportStream`).
    private static let mpeg2SourceExtensions: Set<String> = ["ts", "mts", "cts"]

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey,
    ]

    /// Word-processor types and the reader each is parsed with. The format is passed to
    /// NSAttributedString rather than sniffed: with no type given, AppKit sends a web app's
    /// HTML-written ".doc" export to WebKit, which waits a full minute on the page's remote
    /// images — and one such file froze its whole content batch.
    private static let richTextTypes: [(type: UTType, format: NSAttributedString.DocumentType)] = {
        let pairs: [(UTType?, NSAttributedString.DocumentType)] = [
            (.rtf, .rtf),
            (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
            (UTType("com.microsoft.word.doc"), .docFormat),
            (UTType("org.oasis-open.opendocument.text"), .openDocument),
        ]
        return pairs.compactMap { type, format in type.map { ($0, format) } }
    }()

    static func run(_ request: SearchRequest) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let stop = StopFlag()
            // A thread of its own rather than Swift's cooperative pool: the walk blocks for its
            // whole run, and one that is being abandoned must not hold a thread async work needs.
            DispatchQueue.global(qos: .userInitiated).async {
                walk(request, isStopped: stop.isSet) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in stop.set() }
        }
    }

    /// What one item of the walk leaves it to do, carried out of that item's autorelease pool.
    private enum WalkStep { case next, rootDone, stop }

    /// Synchronous on purpose: `NSEnumerator` cannot be iterated from an async context in Swift 6.
    /// `isStopped` is checked between items and before each file a content search reads, so Stop
    /// takes effect even in the middle of a batch.
    static func walk(
        _ request: SearchRequest, isStopped: @Sendable () -> Bool = { false }, emit: (SearchEvent) -> Void
    ) {
        let options = request.options
        // Tags cost an extended-attribute read per file — measured at half the walk's time — so
        // they are fetched only when they are being searched.
        let resourceKeys = options.searchTags ? resourceKeys.union([.tagNamesKey]) : resourceKeys
        let modifiedCutoff = options.modified.cutoff(from: .now)
        var excludedExtensions: [String: Bool] = [:]
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden { enumeratorOptions.insert(.skipsHiddenFiles) }
        if !options.includePackageContents { enumeratorOptions.insert(.skipsPackageDescendants) }

        let unreadable = OSAllocatedUnfairLock(initialState: 0)
        var pending: [FileHit] = []
        var candidates: [FileHit] = []
        var kinds: [String: String] = [:]
        var scanned = 0
        var reported = 0
        var reachedLimit = false
        var lastFlush = ContinuousClock.now
        let limits = request.limits

        func flush(current: String, force: Bool = false) {
            let now = ContinuousClock.now
            guard force || now - lastFlush >= .milliseconds(120) else { return }
            lastFlush = now
            // Past the limit, not at it: exactly that many matches is every match, not a cut-off.
            if limits.maxResults > 0, reported + pending.count > limits.maxResults {
                pending = Array(pending.prefix(limits.maxResults - reported))
                reachedLimit = true
            }
            if !pending.isEmpty {
                reported += pending.count
                emit(.hits(pending))
                pending.removeAll(keepingCapacity: true)
            }
            emit(.progress(
                scanned: scanned, current: current, unreadable: unreadable.withLock { $0 },
                timedOut: request.nameMatcher.timeouts + request.textMatcher.timeouts))
        }

        func searchCandidateContents() {
            guard !candidates.isEmpty else { return }
            let batch = candidates
            candidates.removeAll(keepingCapacity: true)
            let found = OSAllocatedUnfairLock(initialState: [FileHit]())
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                guard !isStopped() else { return }
                var hit = batch[index]
                // Metadata first: it is a few header bytes, where contents may be a whole document.
                var snippet: Snippet?
                if options.searchMetadata, let metadata = DocumentText.metadataText(of: hit.url) {
                    snippet = request.textMatcher.snippet(in: metadata)
                }
                if snippet == nil, options.searchContents,
                   let text = contentText(
                       of: hit.url, size: hit.size, maxBytes: limits.maxContentBytes,
                       recognizeText: options.recognizeText, isStopped: isStopped,
                       onUnreadable: { unreadable.withLock { $0 += 1 } })
                {
                    snippet = request.textMatcher.snippet(in: text)
                }
                guard let snippet, !isHiddenVideo(hit.url, isRegularFile: hit.size >= 0) else { return }
                hit.snippet = snippet
                let matched = hit
                found.withLock { $0.append(matched) }
            }
            pending.append(contentsOf: found.withLock { $0 })
        }

        func isExcludedKind(_ ext: String) -> Bool {
            guard !options.excludedKinds.isEmpty, !ext.isEmpty else { return false }
            // TypeScript before the type lookup: these extensions declare MPEG-2 video types, and
            // a "Video" exclusion was hiding source files from name searches too. A camcorder's
            // .MTS clip is the other meaning of the extension; see `isHiddenVideo`.
            if mpeg2SourceExtensions.contains(ext) { return false }
            if let cached = excludedExtensions[ext] { return cached }
            let type = UTType(filenameExtension: ext)
            let excluded = type.map { type in options.excludedKinds.contains { type.conforms(to: $0.type) } } ?? false
            excludedExtensions[ext] = excluded
            return excluded
        }

        /// A camcorder's .MTS clip under a Video exclusion, told apart from TypeScript by what the
        /// file holds. Asked only of a file that already matched, and only of a regular file:
        /// every .ts under node_modules would otherwise be opened, and a FIFO would block the walk.
        @Sendable func isHiddenVideo(_ url: URL, isRegularFile: Bool) -> Bool {
            isRegularFile && options.excludedKinds.contains(.video)
                && mpeg2SourceExtensions.contains(url.pathExtension.lowercased())
                && !isPlaceholder(url) && isMPEGTransportStream(url)
        }

        /// Lists a zip's entries by name. Their sizes are unknown, so a size filter leaves them out;
        /// dates are the archive's own.
        func searchArchive(at archive: URL, modified: Date, created: Date) {
            for entry in zipEntries(of: archive) {
                if isStopped() { return }
                let isEntryFolder = entry.hasSuffix("/")
                let path = isEntryFolder ? String(entry.dropLast()) : entry
                let name = (path as NSString).lastPathComponent
                // Finder's resource-fork shadows, not files anyone put in the archive.
                guard !name.isEmpty, !path.hasPrefix("__MACOSX"), !name.hasPrefix("._") else { continue }
                // Every component, as the walk prunes whole folders: "proj/.git/HEAD" is hidden too.
                // Less the "." parts some tools write: `bsdtar` stores "./docs/report.txt", and the
                // "." is not a hidden name. The "./" entry for the archive's top is no entry at all.
                let components = path.split(separator: "/").filter { $0 != "." }
                guard !components.isEmpty else { continue }
                if !options.includeHidden, components.contains(where: { $0.hasPrefix(".") }) { continue }
                if components.dropLast(isEntryFolder ? 0 : 1)
                    .contains(where: { limits.skippedFolderNames.contains($0.lowercased()) })
                {
                    continue
                }
                let wanted = switch options.kind {
                case .filesAndFolders: true
                case .files: !isEntryFolder
                case .folders: isEntryFolder
                }
                let entryExt = (name as NSString).pathExtension.lowercased()
                guard wanted,
                      passesFilters(ext: entryExt, isFolder: isEntryFolder, size: -1, modified: modified),
                      request.nameMatcher.matches(name)
                else { continue }
                pending.append(FileHit(
                    url: archive, archiveEntry: path, name: name, isFolder: isEntryFolder, size: -1,
                    modified: modified, created: created,
                    kind: kind(for: URL(filePath: name), isFolder: isEntryFolder)))
            }
        }

        /// Date, size and kind filters from the options panel.
        func passesFilters(ext: String, isFolder: Bool, size: Int64, modified: Date) -> Bool {
            if let modifiedCutoff, modified < modifiedCutoff { return false }
            if !options.size.accepts(size) { return false }
            return isFolder || !isExcludedKind(ext)
        }

        func kind(for url: URL, isFolder: Bool) -> String {
            if isFolder { return "Folder" }
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty { return "Document" }
            // Neutral for the MPEG-2-declared extensions: "TS File" is true of a TypeScript
            // module and of a transport stream, where the declared kind is true of only one.
            if mpeg2SourceExtensions.contains(ext) { return "\(ext.uppercased()) File" }
            if let cached = kinds[ext] { return cached }
            let description = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) File"
            kinds[ext] = description
            return description
        }

        for root in request.roots {
            // The enumerator does not follow a root that is itself a symlink — a ~/Documents linked
            // to another disk would list nothing — so the link is resolved first.
            let root = root.resolvingSymlinksInPath()
            let rootPath = walkedPath(of: root)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: enumeratorOptions,
                errorHandler: { _, _ in
                    unreadable.withLock { $0 += 1 }
                    return true
                })
            else { continue }

            // A pool per item: the walk is one long block on one thread, and the enumerator and the
            // resource-value reads autorelease as they go, so without one every item's temporaries
            // lived until the walk ended: 163 MB at the peak across /System/Library's 258,000
            // items, 45 MB with the pool.
            while true {
                let step: WalkStep = autoreleasepool {
                    guard let url = enumerator.nextObject() as? URL else { return .rootDone }
                    if isStopped() { return .stop }
                    scanned += 1
                    guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return .next }
                    let isDirectory = values.isDirectory ?? false
                    if isDirectory && (shouldSkipDirectory(url, rootPath: rootPath, options: options)
                        || limits.skippedFolderNames.contains(url.lastPathComponent.lowercased()))
                    {
                        enumerator.skipDescendants()
                        return .next
                    }
                    if !options.includeApplications && isDirectory
                        && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                    {
                        enumerator.skipDescendants()
                        return .next
                    }

                    let isFolder = isDirectory && !(values.isPackage ?? false)
                    let isRegularFile = values.isRegularFile ?? false
                    func makeHit() -> FileHit {
                        FileHit(
                            url: url,
                            name: url.lastPathComponent,
                            isFolder: isFolder,
                            size: isRegularFile ? Int64(values.fileSize ?? 0) : -1,
                            modified: values.contentModificationDate ?? .distantPast,
                            created: values.creationDate ?? .distantPast,
                            kind: kind(for: url, isFolder: isFolder))
                    }

                    let isWantedKind = switch options.kind {
                    case .filesAndFolders: true
                    case .files: !isFolder
                    case .folders: isFolder
                    }
                    let ext = url.pathExtension.lowercased()
                    let isWanted = isWantedKind && passesFilters(
                        ext: ext, isFolder: isFolder, size: isRegularFile ? Int64(values.fileSize ?? 0) : -1,
                        modified: values.contentModificationDate ?? .distantPast)
                    if isWanted {
                        // Cheapest fields first; contents are read later, in parallel, only for items
                        // nothing else matched.
                        if (options.searchNames && request.nameMatcher.matches(url.lastPathComponent))
                            || (options.searchTags && (values.tagNames ?? []).contains(where: request.nameMatcher.matches))
                            || (options.searchComments && finderComment(of: url).map(request.textMatcher.matches) == true)
                        {
                            if !isHiddenVideo(url, isRegularFile: isRegularFile) { pending.append(makeHit()) }
                        } else if options.readsInsideFiles && isRegularFile {
                            candidates.append(makeHit())
                            if candidates.count >= 64 { searchCandidateContents() }
                        }
                    }
                    if options.includeArchiveContents, options.searchNames, isRegularFile, ext == "zip",
                       !isPlaceholder(url)
                    {
                        searchArchive(at: url, modified: values.contentModificationDate ?? .distantPast,
                                      created: values.creationDate ?? .distantPast)
                    }
                    flush(current: url.path)
                    if reachedLimit {
                        emit(.limitReached)
                        return .stop
                    }
                    return .next
                }
                if step == .stop { return }
                if step == .rootDone { break }
            }
            searchCandidateContents()
        }
        flush(current: "", force: true)
        if reachedLimit { emit(.limitReached) }
    }

    /// The path the walk reports a root's items under. Through a root that is itself a symlink,
    /// and canonical rather than `resolvingSymlinksInPath()`: that strips `/private`, while the
    /// enumerator yields `/private/var/...` for a root under `/var`.
    static func walkedPath(of root: URL) -> String {
        let root = root.resolvingSymlinksInPath()
        return (try? root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? root.path
    }

    /// Whether a file is an MPEG transport stream: a sync byte 0x47 at the start of each of its
    /// first three packets, 188 bytes apart, or 192 apart with a 4-byte timestamp ahead of each
    /// (the BDAV packets of AVCHD). One byte would be a TypeScript file starting with "G".
    static func isMPEGTransportStream(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 400) else { return false }
        func syncs(at first: Int, every stride: Int) -> Bool {
            (0..<3).allSatisfy { $0 * stride + first < head.count && head[head.startIndex + $0 * stride + first] == 0x47 }
        }
        return syncs(at: 0, every: 188) || syncs(at: 4, every: 192)
    }

    /// Folders pruned before the walk descends into them. `rootPath` is the resolved root being
    /// walked: a system folder is only excluded when the walk reaches it from above, so a root the
    /// user chose inside one (`/Library/Fonts`, or a temp folder under `/private`) is still searched.
    static func shouldSkipDirectory(_ url: URL, rootPath: String = "/", options: SearchOptions) -> Bool {
        let path = url.path
        // Always: reached through "/", these are duplicates (the data volume behind the
        // firmlinks, other mounted volumes that get their own root) or not files at all.
        if ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd"]
            .contains(path)
        {
            return true
        }
        func isWithin(_ candidate: String, _ folder: String) -> Bool {
            candidate == folder || candidate.hasPrefix(folder + "/")
        }
        func pruned(_ folders: [String]) -> Bool {
            folders.contains { isWithin(path, $0) && !isWithin(rootPath, $0) }
        }
        if !options.includeApplications && pruned(applicationFolders) { return true }
        return options.excludeSystemFolders && pruned(systemFolders)
    }

    static let applicationFolders = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]

    static let systemFolders = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores",
    ]

    /// The comment typed into Finder's Get Info window. Finder keeps it in an extended attribute as a
    /// binary property list; the `.DS_Store` copy is a cache of this, not the source.
    static func finderComment(of url: URL) -> String? {
        let name = "com.apple.metadata:kMDItemFinderComment"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }

    /// An iCloud file that is not downloaded: reading it would download it.
    static func isPlaceholder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// The entry paths in a zip archive, read from its central directory by `bsdtar` — no
    /// extraction. Encrypted archives still list, as their names are not encrypted; an unreadable
    /// or corrupt one yields nothing.
    static func zipEntries(of archive: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-tf", archive.path]
        // Pinned rather than inherited: launched from Finder there is no LANG, and in the C locale
        // every non-ASCII byte of a name is printed as "?".
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A truncated or corrupt archive lists what it could before failing, and junk that is not
        // an archive can print its own text as if it were names; zipinfo listed neither.
        guard process.terminationStatus == 0 else { return [] }
        // Lossy per byte: bsdtar escapes a C1 control character's second byte alone, and a strict
        // decode would then fall back to Latin-1 and turn every other name to mojibake. Split on
        // "\n" only, the one separator bsdtar writes; it escapes control characters within names.
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Plain text, PDF and word-processor documents. Anything else is sniffed: no NUL bytes in the
    /// first 8 KB means it is treated as text, which catches source files with unknown extensions.
    ///
    /// `isStopped` is checked between the steps of a long extraction — OCR page by page, an
    /// archive chunk by chunk. The walk passes its own: it runs on plain threads, where
    /// `Task.isCancelled` is always false.
    static func contentText(
        of url: URL, size: Int64, maxBytes: Int = SearchLimits().maxContentBytes, recognizeText: Bool = false,
        isStopped: () -> Bool = { Task.isCancelled }, onUnreadable: () -> Void = {}, capsExtractions: Bool = true
    ) -> String? {
        guard size > 0, size <= maxBytes, !isStopped() else { return nil }
        // An iCloud file that is not downloaded is a placeholder, and reading it downloads it — a
        // content search of iCloud Drive would otherwise pull the whole drive down.
        if isPlaceholder(url) { return nil }
        // Counted, not skipped in silence: a file the search cannot open must not look like a
        // file that simply does not contain the words.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            onUnreadable()
            return nil
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let ext = url.pathExtension.lowercased()

        if let type, type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else {
                onUnreadable()
                return nil
            }
            let text = document.string ?? ""
            // Next to no text across the pages means a scan: pictures of pages, not text.
            if recognizeText, text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 * max(document.pageCount, 1) / 10 {
                return DocumentText.recognizedText(inScannedPDF: document, isStopped: isStopped)
            }
            return text
        }
        // SVG is an image written as text: its words are read directly, where OCR would find none.
        if recognizeText, let type, type.conforms(to: .image), !type.conforms(to: .text) {
            return DocumentText.recognizedText(inImageAt: url, isStopped: isStopped)
        }
        // Set once a word-processor parse has failed: only then can a ".doc" be HTML wearing the
        // wrong name. Sniffed for every file it would send PHP views, templates and Markdown
        // that open with `<!doctype html` through the tag stripper, which empties them.
        var mayBeHTML = false
        if let format = richTextTypes.first(where: { type?.conforms(to: $0.type) == true })?.format
            ?? misnamedWordFormats[ext]
        {
            let parsed = DocumentText.withHeavySlot(isStopped: isStopped, capped: capsExtractions) {
                wordProcessorText(at: url, format: format) ?? misnamedWordText(at: url, tried: format)
            }
            if let parsed { return parsed }
            if isStopped() { return nil }
            // A failed parse falls through to the sniff below: the usual culprit is HTML wearing
            // a ".doc" extension, which the sniff reads as the text it is.
            mayBeHTML = true
        }
        if let members = DocumentText.zipMembers(forExtension: ext) {
            return DocumentText.withHeavySlot(isStopped: isStopped, capped: capsExtractions) {
                DocumentText.zipText(
                    of: url, members: members, maxBytes: maxBytes, isStopped: isStopped, onUnreadable: onUnreadable)
            }
        }
        // Every other file is sniffed, whatever its declared type: macOS files `.ts` as an MPEG-2
        // video stream, and `.plist`, `.eml` and `.pem` as types that are not text, though each is
        // usually plain text. A real video or binary plist has a NUL within its first 8 KB.
        //
        // A plain read: decoding copies the bytes anyway, and a mapped file whose volume goes
        // away mid-read takes the process down with SIGBUS. The first 8 KB alone decides a file is
        // binary, so only that much is read to turn one down, not the whole file.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Readable by `access`, yet not openable: a privacy prompt (TCC) the user has not
            // allowed answers EPERM only here.
            onUnreadable()
            return nil
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192), !isBinary(head),
              (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.readToEnd(), let text = decode(data)
        else {
            // A word-processor file nothing could read: a password-protected one is an OLE
            // container the readers refuse and the sniff takes for binary.
            if mayBeHTML { onUnreadable() }
            return nil
        }
        // Web pages are searched for what they say, not for their tags and scripts.
        if (type?.conforms(to: .html) ?? false) || (mayBeHTML && looksLikeHTML(text)) {
            return DocumentText.markupText(text, isStopped: isStopped)
        }
        return text
    }

    /// Readers for the word-processor extensions that conform to none of `richTextTypes`:
    /// macro-enabled and template variants, which AppKit reads as the format they extend.
    private static let misnamedWordFormats: [String: NSAttributedString.DocumentType] = [
        "docm": .officeOpenXML, "dotx": .officeOpenXML, "dotm": .officeOpenXML,
        "dot": .docFormat, "ott": .openDocument,
    ]

    private static func wordProcessorText(at url: URL, format: NSAttributedString.DocumentType) -> String? {
        try? NSAttributedString(url: url, options: [.documentType: format], documentAttributes: nil).string
    }

    /// Text from a word-processor file whose extension named the wrong format (`tried`), chosen
    /// by what the file starts with: RTF saved as ".doc", a ".docx" that is a Word 97 file, an
    /// OpenDocument text named ".doc", Word 2003 XML. The format is still passed, never sniffed,
    /// so HTML does not reach WebKit (see `richTextTypes`).
    private static func misnamedWordText(at url: URL, tried: NSAttributedString.DocumentType) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 1024) else {
            return nil
        }
        defer { try? handle.close() }
        let formats: [NSAttributedString.DocumentType]
        if head.starts(with: Array(#"{\rtf"#.utf8)) {
            formats = [.rtf]
        } else if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            formats = [.officeOpenXML, .openDocument]
        } else if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
            formats = [.docFormat]
        } else if String(decoding: head, as: UTF8.self).contains("<?xml"),
                  String(decoding: head, as: UTF8.self).contains("wordDocument")
        {
            // Word 2003 XML: the text is in the tags, so it reads as markup.
            guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd(),
                  let text = decode(data)
            else { return nil }
            return DocumentText.markupText(text)
        } else {
            return nil
        }
        for format in formats where format != tried {
            if let text = wordProcessorText(at: url, format: format) { return text }
        }
        return nil
    }

    /// HTML by content, for a file whose extension says otherwise.
    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(256).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    static func decode(_ data: Data) -> String? {
        // A lossy fallback, as UTF-8 gets below: one lone surrogate otherwise made the whole
        // file unsearchable.
        if hasUTF16Mark(data) { return String(data: data, encoding: .utf16) ?? utf16Lossy(data) }
        if isBinary(data) { return nil }
        // Latin-1 last: it accepts every byte, including the five Windows-1252 leaves undefined
        // (0x81, 0x8D, 0x8F, 0x90, 0x9D), which Mac Roman text uses for letters.
        if let text = String(data: data, encoding: .utf8) { return text }
        // One stray byte fails the strict decode, and Windows-1252 would then turn every "é" in
        // an otherwise UTF-8 file into "Ã©". Valid multi-byte sequences outnumbering the bad
        // ones say UTF-8 with a flaw; a Windows-1252 file's accented letters, single high bytes,
        // almost never form one.
        let lossy = String(decoding: data, as: UTF8.self)
        var valid = 0, invalid = 0
        for scalar in lossy.unicodeScalars where scalar.value >= 0x80 {
            if scalar == "\u{FFFD}" { invalid += 1 } else { valid += 1 }
        }
        if valid > invalid { return lossy }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// UTF-16 unit by unit, replacing a lone surrogate with U+FFFD rather than refusing the file.
    private static func utf16Lossy(_ data: Data) -> String {
        let big = data.starts(with: [0xFE, 0xFF])
        let payload = Array(data.dropFirst(2))
        var units = [UInt16]()
        units.reserveCapacity(payload.count / 2)
        var index = 0
        while index + 1 < payload.count {
            let (first, second) = (UInt16(payload[index]), UInt16(payload[index + 1]))
            units.append(big ? first << 8 | second : second << 8 | first)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A NUL byte in the first 8 KB, with no UTF-16 byte order mark to account for it.
    static func isBinary(_ data: Data) -> Bool {
        !hasUTF16Mark(data) && data.prefix(8192).contains(0)
    }

    private static func hasUTF16Mark(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    }
}

/// Set once when a search's consumer goes away; read by the walk and its content workers.
final class StopFlag: Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    func set() { stopped.withLock { $0 = true } }
    @Sendable func isSet() -> Bool { stopped.withLock { $0 } }
}

extension KindGroup {
    var type: UTType {
        switch self {
        case .images: .image
        case .video: .movie
        case .audio: .audio
        case .archives: .archive
        }
    }
}

/// Files with identical contents. Same size first, which costs nothing; then a hash of the first
/// 64 KB, which is cheap; and a full SHA-256 only for files that match that far — so most files
/// are never read at all, and big ones only when they might really be copies.
enum DuplicateFinder {
    struct Candidate: Sendable {
        let id: FileHit.ID
        let url: URL
        let size: Int64
    }

    struct Found: Sendable {
        /// Largest set first.
        var sets: [[FileHit.ID]] = []
        /// Files that had a same-size partner but could not be read, so were never compared: iCloud
        /// placeholders, unreadable files, and files changed since the search.
        var unread = 0
    }

    static func sets(in candidates: [Candidate]) -> Found {
        let headLength = 64 * 1024
        // Checked per file: hashing a big library takes minutes, and whoever asked may have moved on.
        // A cancelled file hashes to nil, so it joins no set; the partial result is discarded.
        func digest(of candidate: Candidate, limit: Int?) -> String? {
            Task.isCancelled ? nil : Self.digest(of: candidate.url, limit: limit, size: candidate.size)
        }
        var found = Found()
        for sameSize in Dictionary(grouping: candidates, by: \.size).values where sameSize.count > 1 {
            if Task.isCancelled { return Found() }
            for (head, sameHead) in Dictionary(grouping: sameSize, by: { digest(of: $0, limit: headLength) }) {
                guard head != nil else {
                    found.unread += sameHead.count
                    continue
                }
                guard sameHead.count > 1 else { continue }
                let identical = sameSize[0].size <= Int64(headLength)
                    ? [head: sameHead]
                    : Dictionary(grouping: sameHead, by: { digest(of: $0, limit: nil) })
                for (whole, set) in identical {
                    if whole == nil {
                        found.unread += set.count
                    } else if set.count > 1 {
                        found.sets.append(set.map(\.id))
                    }
                }
            }
        }
        found.sets.sort { $0.count > $1.count }
        return found
    }

    /// SHA-256 of the first `limit` bytes, or of everything. Nil for a file that cannot be read
    /// or is an iCloud placeholder, which reading would download.
    ///
    /// `size` is the size the search recorded. A read error, or a file that has grown or shrunk
    /// since, is nil too: a hash of a cut-short stream can equal another file's, and the head
    /// hash stands in for the whole one on a small file.
    static func digest(of url: URL, limit: Int?, size: Int64) -> String? {
        if SearchEngine.isPlaceholder(url) { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read = 0
        while limit.map({ read < $0 }) ?? true {
            // Not `try?`: that flattens a read error into the nil that means end of file.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(1 << 20, limit.map { $0 - read } ?? 1 << 20))
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            read += chunk.count
        }
        guard Int64(read) == limit.map({ min(Int64($0), size) }) ?? size else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
