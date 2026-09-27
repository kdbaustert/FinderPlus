import AppKit
import os
import PDFKit
import UniformTypeIdentifiers

struct FileHit: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isFolder: Bool
    /// -1 for folders and packages, whose size the walk does not total.
    let size: Int64
    let modified: Date
    let kind: String
    var snippet: Snippet?

    var id: URL { url }
    var parentPath: String { url.deletingLastPathComponent().path }
    var snippetText: String { snippet?.text ?? "" }

    var displayParent: String {
        let home = NSHomeDirectory()
        let parent = parentPath
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    var sizeText: String {
        size < 0 ? "—" : size.formatted(.byteCount(style: .file))
    }
}

enum SearchEvent: Sendable {
    case hits([FileHit])
    case progress(scanned: Int, current: String, unreadable: Int)
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

    init(roots: [URL], query: String, options: SearchOptions, limits: SearchLimits = SearchLimits()) throws {
        self.roots = roots
        self.options = options
        self.limits = SearchLimits(
            maxContentBytes: limits.maxContentBytes,
            maxResults: limits.maxResults,
            skippedFolderNames: Set(limits.skippedFolderNames.map { $0.lowercased() }))
        nameMatcher = try QueryMatcher(query: query, options: options, anchorsWildcards: true)
        textMatcher = try QueryMatcher(query: query, options: options, anchorsWildcards: false)
    }
}

/// A live, index-free walk of the file system, like EasyFind's: slower than Spotlight, but it sees
/// hidden, system and never-indexed files.
enum SearchEngine {

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]

    private static let richTextTypes: [UTType] = [
        .rtf,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    static func run(_ request: SearchRequest) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                walk(request) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous on purpose: `NSEnumerator` cannot be iterated from an async context in Swift 6.
    /// Cancellation still works — `Task.isCancelled` reads the detached task this runs on.
    static func walk(_ request: SearchRequest, emit: (SearchEvent) -> Void) {
        let options = request.options
        // Tags cost an extended-attribute read per file — measured at half the walk's time — so
        // they are fetched only when they are being searched.
        let resourceKeys = options.searchTags ? resourceKeys.union([.tagNamesKey]) : resourceKeys
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
            if limits.maxResults > 0, reported + pending.count >= limits.maxResults {
                pending = Array(pending.prefix(limits.maxResults - reported))
                reachedLimit = true
            }
            if !pending.isEmpty {
                reported += pending.count
                emit(.hits(pending))
                pending.removeAll(keepingCapacity: true)
            }
            emit(.progress(scanned: scanned, current: current, unreadable: unreadable.withLock { $0 }))
        }

        func searchCandidateContents() {
            guard !candidates.isEmpty else { return }
            let batch = candidates
            candidates.removeAll(keepingCapacity: true)
            let found = OSAllocatedUnfairLock(initialState: [FileHit]())
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                var hit = batch[index]
                guard let text = contentText(of: hit.url, size: hit.size, maxBytes: limits.maxContentBytes),
                      let snippet = request.textMatcher.snippet(in: text)
                else { return }
                hit.snippet = snippet
                let matched = hit
                found.withLock { $0.append(matched) }
            }
            pending.append(contentsOf: found.withLock { $0 })
        }

        func kind(for url: URL, isFolder: Bool) -> String {
            if isFolder { return "Folder" }
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty { return "Document" }
            if let cached = kinds[ext] { return cached }
            let description = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) File"
            kinds[ext] = description
            return description
        }

        for root in request.roots {
            // The canonical path, not `resolvingSymlinksInPath()`: that strips `/private`, while the
            // enumerator yields `/private/var/...` for a root under `/var`.
            let rootPath = (try? root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? root.path
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: enumeratorOptions,
                errorHandler: { _, _ in
                    unreadable.withLock { $0 += 1 }
                    return true
                })
            else { continue }

            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return }
                scanned += 1
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
                let isDirectory = values.isDirectory ?? false
                if isDirectory && (shouldSkipDirectory(url, rootPath: rootPath, options: options)
                    || limits.skippedFolderNames.contains(url.lastPathComponent.lowercased()))
                {
                    enumerator.skipDescendants()
                    continue
                }
                if !options.includeApplications && isDirectory
                    && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                {
                    enumerator.skipDescendants()
                    continue
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
                        kind: kind(for: url, isFolder: isFolder))
                }

                let isWanted = switch options.kind {
                case .filesAndFolders: true
                case .files: !isFolder
                case .folders: isFolder
                }
                if isWanted {
                    // Cheapest fields first; contents are read later, in parallel, only for items
                    // nothing else matched.
                    if (options.searchNames && request.nameMatcher.matches(url.lastPathComponent))
                        || (options.searchTags && (values.tagNames ?? []).contains(where: request.nameMatcher.matches))
                        || (options.searchComments && finderComment(of: url).map(request.textMatcher.matches) == true)
                    {
                        pending.append(makeHit())
                    } else if options.searchContents && isRegularFile {
                        candidates.append(makeHit())
                        if candidates.count >= 64 { searchCandidateContents() }
                    }
                }
                flush(current: url.path)
                if reachedLimit {
                    emit(.limitReached)
                    return
                }
            }
            searchCandidateContents()
        }
        flush(current: "", force: true)
        if reachedLimit { emit(.limitReached) }
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

    /// Plain text, PDF and word-processor documents. Anything else is sniffed: no NUL bytes in the
    /// first 8 KB means it is treated as text, which catches source files with unknown extensions.
    static func contentText(of url: URL, size: Int64, maxBytes: Int = SearchLimits().maxContentBytes) -> String? {
        guard size > 0, size <= maxBytes else { return nil }
        // An iCloud file that is not downloaded is a placeholder, and reading it downloads it — a
        // content search of iCloud Drive would otherwise pull the whole drive down.
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
        let type = UTType(filenameExtension: url.pathExtension)

        if let type, type.conforms(to: .pdf) {
            return PDFDocument(url: url)?.string
        }
        if let type, richTextTypes.contains(where: type.conforms(to:)) {
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        let isText = type?.conforms(to: .text) ?? false
        let isUnknown = type == nil || type?.isDynamic == true
        guard isText || isUnknown else { return nil }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }
}
