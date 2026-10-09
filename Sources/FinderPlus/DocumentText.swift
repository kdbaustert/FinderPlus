import AppKit
import AudioToolbox
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Searchable text from inside files that are not plain text: office documents, ebooks, web
/// pages, images and scans, and the metadata a file carries. Everything here runs on the walk's
/// worker threads, never on the main thread.
enum DocumentText {
    // MARK: - Zipped XML documents

    /// Office Open XML, OpenDocument and EPUB files are zip archives of XML. These are the
    /// members that hold their text, one `bsdtar` call each and in this order; `bsdtar` matches
    /// the patterns itself, and its `*` crosses folders.
    ///
    /// Separate calls because `bsdtar -xO` writes members in archive order, and Excel stores
    /// `sharedStrings.xml` after the worksheets: read in one call, a workbook whose sheets
    /// filled `maxBytes` never got to its text.
    static func zipMembers(forExtension ext: String) -> [String]? {
        switch ext {
        case "xlsx", "xlsm", "xltx", "xltm": ["xl/sharedStrings.xml", "xl/worksheets/*.xml"]
        case "pptx", "pptm", "ppsx", "ppsm", "potx", "potm": ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"]
        case "ods", "odp", "odg": ["content.xml"]
        case "epub": ["*.xhtml", "*.html", "*.htm"]
        default: nil
        }
    }

    /// Extractions of zip and word-processor files running at once. Each holds the file's XML
    /// whole, and `concurrentPerform` runs one per core: eight 11 MB workbooks peaked at 10 GB.
    private static let heavySlots = DispatchSemaphore(value: 3)

    /// Runs `body` once one of the `heavySlots` is free; nil if the search is stopped first.
    /// `capped` false for the preview, which must not queue behind a search's extractions.
    static func withHeavySlot<T>(isStopped: () -> Bool, capped: Bool = true, _ body: () -> T?) -> T? {
        guard capped else { return body() }
        while heavySlots.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if isStopped() { return nil }
        }
        defer { heavySlots.signal() }
        return body()
    }

    /// Streams each member pattern out with `bsdtar -xO`, stopping once `maxBytes` have been read
    /// in all, and returns their text without markup. `bsdtar` rather than `unzip`: unzip expands
    /// `[`, `?` and `*` in the archive's own file name too, so "Q[1].xlsx" was read as a sibling
    /// "Q1.xlsx" whenever one existed.
    ///
    /// `onUnreadable` is called when nothing could be read and `bsdtar` failed — an encrypted
    /// workbook is an OLE container behind a zip name, which it cannot open. A pattern that
    /// matches no member also fails, so one failure among members that did read is not counted.
    static func zipText(
        of url: URL, members: [String], maxBytes: Int, isStopped: () -> Bool = { Task.isCancelled },
        onUnreadable: () -> Void = {}
    ) -> String? {
        var remaining = maxBytes
        var texts: [String] = []
        var failed = false
        for member in members where remaining > 0 {
            let (data, didFail) = extract(member, from: url, maxBytes: remaining, isStopped: isStopped)
            failed = failed || didFail
            if isStopped() { return nil }
            guard !data.isEmpty else { continue }
            remaining -= data.count
            // A worksheet cell with t="s" holds an index into sharedStrings.xml, not text: left in,
            // every number up to the string count matched a content search.
            let text = data.withUnsafeBytes {
                stripMarkup($0.bindMemory(to: UInt8.self), dropsSharedStringCells: true, isStopped: isStopped)
            }
            texts.append(text)
        }
        if isStopped() { return nil }
        if texts.isEmpty {
            if failed { onUnreadable() }
            return nil
        }
        return texts.joined(separator: " ")
    }

    /// One member pattern's bytes, and whether `bsdtar` failed without producing any.
    private static func extract(
        _ member: String, from url: URL, maxBytes: Int, isStopped: () -> Bool
    ) -> (data: Data, failed: Bool) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-xOf", url.path, member]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // No stdin: asked for a passphrase (an encrypted member, run under a terminal), bsdtar
        // then fails at once instead of waiting on a prompt nobody sees.
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (Data(), true) }
        var data = Data()
        while data.count < maxBytes, !isStopped(),
              let chunk = try? output.fileHandleForReading.read(upToCount: 1 << 16), !chunk.isEmpty
        {
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (data, data.isEmpty && process.terminationStatus != 0)
    }

    /// Text from HTML or XML. A block-level tag becomes a space; an inline one — a styled run, a
    /// link, a span — becomes nothing, so a word split across runs ("<a:t>Quar</a:t>
    /// <a:t>terly</a:t>", or a drop-cap "<span>Q</span>uarterly") stays one word; scripts and
    /// styles are dropped entirely, and so are run properties and ruby annotations.
    static func markupText(_ markup: String, isStopped: () -> Bool = { false }) -> String {
        var markup = markup
        return markup.withUTF8 { stripMarkup($0, dropsSharedStringCells: false, isStopped: isStopped) }
    }

    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let slash = UInt8(ascii: "/")

    /// One scan over the UTF-8 bytes, writing the text out as it goes. Swift `Regex` passes over
    /// the same text — one per tag kind — cost 6 seconds and 1.2 GB for a 50 MB worksheet, ran for
    /// seconds between Stop checks, and the worksheets of one folder peaked at 10 GB. This reads
    /// `isStopped` every 64 KB instead.
    ///
    /// `dropsSharedStringCells` removes `<c … t="s">…</c>` cells, with or without a namespace
    /// prefix; a self-closing `<c t="s"/>` ends at its own `/>` rather than swallowing the next
    /// cell.
    private static func stripMarkup(
        _ input: UnsafeBufferPointer<UInt8>, dropsSharedStringCells: Bool, isStopped: () -> Bool
    ) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(input.count / 2)
        let count = input.count
        var index = 0
        var checkedAt = 0
        // Once no `>` is left, every later `<` is plain text: searching on would rescan the rest
        // of the text from each one.
        var hasTagEnd = true
        // Elements whose closing tag was not found, so they are not searched for again: a file
        // of unclosed <script> tags would otherwise rescan to the end from each.
        var unclosed: Set<String> = []

        func tagEnd(from start: Int) -> Int? {
            guard hasTagEnd else { return nil }
            var position = start
            while position < count {
                if input[position] == greaterThan { return position }
                position += 1
            }
            hasTagEnd = false
            return nil
        }

        while index < count {
            if index - checkedAt >= 1 << 16 {
                if isStopped() { return "" }
                checkedAt = index
            }
            let byte = input[index]
            if byte == lessThan, let close = tagEnd(from: index + 1) {
                index = consumeTag(
                    in: input, at: index, close: close, into: &output, unclosed: &unclosed,
                    dropsSharedStringCells: dropsSharedStringCells)
            } else if byte == UInt8(ascii: "&"), let (scalar, next) = entity(in: input, at: index) {
                UTF8.encode(scalar) { output.append($0) }
                index = next
            } else {
                output.append(byte)
                index += 1
            }
        }
        if isStopped() { return "" }
        return String(decoding: collapsingWhitespace(output), as: UTF8.self)
    }

    /// The tag from `<` at `start` to its `>` at `close`: what it leaves in `output`, and the
    /// index after the tag — or after the element, for one whose content goes with it.
    private static func consumeTag(
        in input: UnsafeBufferPointer<UInt8>, at start: Int, close: Int, into output: inout [UInt8],
        unclosed: inout Set<String>, dropsSharedStringCells: Bool
    ) -> Int {
        let isClosing = start + 1 < close && input[start + 1] == slash
        let nameStart = start + (isClosing ? 2 : 1)
        var nameEnd = nameStart
        while nameEnd < close, !isNameEnd(input[nameEnd]) { nameEnd += 1 }
        let name = lowercasedName(input, nameStart..<nameEnd)
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let isSelfClosing = input[close - 1] == slash

        // A self-closing tag has no content to drop: `<script src="…"/>` would otherwise take
        // everything up to the next `</script>` with it, an EPUB chapter among it.
        if !isClosing, !isSelfClosing, !name.isEmpty, !unclosed.contains(name) {
            var replacement: UInt8?
            if name == "script" || name == "style" {
                replacement = UInt8(ascii: " ")
            } else if name == "rt" || name == "rp" || local == "rpr" {
                // Ruby annotations fuse into the base text ("漢かん字"), and run properties hold
                // child tags (<sz>, <color>, <a:solidFill>) that each became a space inside a word.
                replacement = 0
            } else if dropsSharedStringCells, local == "c", hasStringType(input, nameEnd..<close) {
                replacement = UInt8(ascii: " ")
            }
            if let replacement {
                if let after = closingTagEnd(of: input, nameRange: nameStart..<nameEnd, from: close + 1) {
                    if replacement != 0 { output.append(replacement) }
                    return after
                }
                unclosed.insert(name)
            }
        }
        // Office Open XML runs by local name, whatever the prefix: `x:r` and `x:t` as much as
        // `a:r`. Not for the rest: ODF's `text:s` is a space, though `s` alone is HTML's strike.
        let isRun = name != local && ["r", "t", "is", "rpr"].contains(local)
        if !isRun, !inlineTagNames.contains(name) { output.append(UInt8(ascii: " ")) }
        return close + 1
    }

    private static func isNameEnd(_ byte: UInt8) -> Bool {
        byte == slash || byte == UInt8(ascii: " ") || (byte >= 9 && byte <= 13)
    }

    /// ASCII-lowercased; empty for a name too long to be in `inlineTagNames`.
    private static func lowercasedName(_ input: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        guard range.count <= 15 else { return "" }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { buffer in
            for (offset, position) in range.enumerated() { buffer[offset] = lowercased(input[position]) }
            return String(decoding: UnsafeBufferPointer(rebasing: buffer[0..<range.count]), as: UTF8.self)
        }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    /// Whether an opening tag carries `t="s"` as an attribute of its own.
    private static func hasStringType(_ input: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        let pattern = Array(#"t="s""#.utf8)
        let alternate = Array("t='s'".utf8)
        var position = range.lowerBound
        while position + pattern.count <= range.upperBound {
            if position > range.lowerBound, isNameEnd(input[position - 1]) {
                let candidate = input[position..<position + pattern.count]
                if candidate.elementsEqual(pattern) || candidate.elementsEqual(alternate) { return true }
            }
            position += 1
        }
        return false
    }

    /// The index after the `>` of the next `</name>`, compared without regard to case.
    private static func closingTagEnd(
        of input: UnsafeBufferPointer<UInt8>, nameRange: Range<Int>, from start: Int
    ) -> Int? {
        let count = input.count
        let length = nameRange.count
        var position = start
        while position + 2 + length < count {
            if input[position] == lessThan, input[position + 1] == slash {
                var matches = true
                for offset in 0..<length where lowercased(input[position + 2 + offset]) != lowercased(input[nameRange.lowerBound + offset]) {
                    matches = false
                    break
                }
                if matches, input[position + 2 + length] == greaterThan || isNameEnd(input[position + 2 + length]) {
                    var end = position + 2 + length
                    while end < count, input[end] != greaterThan { end += 1 }
                    return end < count ? end + 1 : nil
                }
            }
            position += 1
        }
        return nil
    }

    /// One character reference at `start` (an ampersand): the scalar and the index after its
    /// semicolon. One pass, so "&amp;lt;" decodes to "&lt;" and no further. An unknown name, or a
    /// number that is no scalar, is left as written.
    private static func entity(in input: UnsafeBufferPointer<UInt8>, at start: Int) -> (Unicode.Scalar, Int)? {
        let count = input.count
        var end = start + 1
        // The longest reference is 33 bytes with its semicolon.
        while end < count, end - start <= 33, input[end] != UInt8(ascii: ";") { end += 1 }
        guard end < count, input[end] == UInt8(ascii: ";"), end - start >= 3 else { return nil }
        let body = input[(start + 1)..<end]
        func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        func isHex(_ byte: UInt8) -> Bool { isDigit(byte) || (lowercased(byte) >= 97 && lowercased(byte) <= 102) }
        func isAlpha(_ byte: UInt8) -> Bool { lowercased(byte) >= 97 && lowercased(byte) <= 122 }
        var scalar: Unicode.Scalar?
        if body.first == UInt8(ascii: "#") {
            let isHexadecimal = body.dropFirst().first.map { lowercased($0) == UInt8(ascii: "x") } ?? false
            let digits = body.dropFirst(isHexadecimal ? 2 : 1)
            guard isHexadecimal ? (1...6).contains(digits.count) && digits.allSatisfy(isHex)
                    : (1...7).contains(digits.count) && digits.allSatisfy(isDigit)
            else { return nil }
            scalar = UInt32(String(decoding: digits, as: UTF8.self), radix: isHexadecimal ? 16 : 10)
                .flatMap(Unicode.Scalar.init)
        } else {
            guard (2...32).contains(body.count), isAlpha(body.first!), body.allSatisfy({ isAlpha($0) || isDigit($0) })
            else { return nil }
            scalar = namedEntities[String(decoding: body, as: UTF8.self)]
        }
        guard let scalar, scalar != "\0" else { return nil }
        return (scalar, end + 1)
    }

    /// Each run of white space becomes one space, and a soft hyphen goes: it sits inside a word,
    /// and "Quar\u{AD}terly" would never match "quarterly". After the entities, so "&shy;" goes
    /// with it. Works on the bytes in place, for the characters `\s` matches in UTF-8.
    private static func collapsingWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        var write = 0
        var read = 0
        var inSpace = false
        let count = bytes.count
        while read < count {
            let byte = bytes[read]
            var length = 1
            var isSpace = false
            if byte == 0x20 || (byte >= 9 && byte <= 13) {
                isSpace = true
            } else if byte == 0xC2, read + 1 < count {
                if bytes[read + 1] == 0xAD {
                    read += 2
                    continue
                }
                (length, isSpace) = (2, bytes[read + 1] == 0x85 || bytes[read + 1] == 0xA0)
            } else if byte == 0xE1, read + 2 < count {
                (length, isSpace) = (3, bytes[read + 1] == 0x9A && bytes[read + 2] == 0x80)
            } else if byte == 0xE2, read + 2 < count {
                let (second, third) = (bytes[read + 1], bytes[read + 2])
                length = 3
                isSpace = (second == 0x80 && ((0x80...0x8A).contains(third) || [0xA8, 0xA9, 0xAF].contains(third)))
                    || (second == 0x81 && third == 0x9F)
            } else if byte == 0xE3, read + 2 < count {
                (length, isSpace) = (3, bytes[read + 1] == 0x80 && bytes[read + 2] == 0x80)
            }
            if isSpace {
                if !inSpace { bytes[write] = 0x20; write += 1 }
                inSpace = true
            } else {
                inSpace = false
                for offset in 0..<length {
                    bytes[write] = bytes[read + offset]
                    write += 1
                }
            }
            read += length
        }
        bytes.removeLast(count - write)
        return bytes
    }

    /// Tags that wrap text within a line, across HTML, Office Open XML's runs and OpenDocument's
    /// spans. Everything not named here — including an unknown tag — still reads as a space,
    /// which separates words where the markup separated them.
    private static let inlineTagNames: Set<String> = [
        // HTML.
        "a", "abbr", "acronym", "b", "bdi", "bdo", "big", "cite", "code", "data", "del", "dfn",
        "em", "font", "i", "ins", "kbd", "mark", "nobr", "q", "rp", "rt", "ruby", "s", "samp",
        "small", "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr",
        // Office Open XML: a run, its properties and its text, in slides and in shared strings.
        "r", "rpr", "t", "is",
        // OpenDocument.
        "text:span", "text:a",
    ]

    /// HTML's named characters for Latin-1 and typography, the ones text actually uses. Greek
    /// letters and maths symbols are left out. A non-breaking space reads as a plain one, so
    /// "a&nbsp;b" matches "a b".
    private static let namedEntities: [String: Unicode.Scalar] = {
        var table: [String: Unicode.Scalar] = [
            "quot": "\"", "amp": "&", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
            "OElig": "\u{152}", "oelig": "\u{153}", "Scaron": "\u{160}", "scaron": "\u{161}", "Yuml": "\u{178}",
            "fnof": "\u{192}", "circ": "\u{2C6}", "tilde": "\u{2DC}", "ensp": "\u{2002}", "emsp": "\u{2003}",
            "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "ndash": "\u{2013}", "mdash": "\u{2014}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
            "bdquo": "\u{201E}", "dagger": "\u{2020}", "Dagger": "\u{2021}", "bull": "\u{2022}",
            "hellip": "\u{2026}", "permil": "\u{2030}", "prime": "\u{2032}", "Prime": "\u{2033}",
            "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "euro": "\u{20AC}", "trade": "\u{2122}",
        ]
        // U+00A1 to U+00FF, in code point order.
        let latin1 = """
            iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn \
            sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest \
            Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute \
            Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc \
            Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute \
            ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide \
            oslash ugrave uacute ucirc uuml yacute thorn yuml
            """
        for (offset, name) in latin1.split(separator: " ").enumerated() {
            table[String(name)] = Unicode.Scalar(0xA1 + UInt32(offset))
        }
        return table
    }()

    // MARK: - Text recognition

    /// Text read out of an image. The image is loaded no larger than 3000 pixels on its longest
    /// side: enough for Vision to read body text, without decoding a 50-megapixel photo whole.
    static func recognizedText(inImageAt url: URL, isStopped: () -> Bool = { Task.isCancelled }) -> String? {
        // Checked before decoding and recognition, which cannot be interrupted once started: a
        // preview that has moved on, or a search that was stopped, must not keep a core busy on
        // text nobody will see.
        guard !isStopped(), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return recognizedText(in: image)
    }

    /// A scanned PDF has pages but no text layer; each page is rendered and read like an image.
    /// Long scans stop at `maxPages`, which bounds how long one file can hold up a search.
    static func recognizedText(
        inScannedPDF document: PDFDocument, maxPages: Int = 30, isStopped: () -> Bool = { Task.isCancelled }
    ) -> String? {
        var pages: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            if isStopped() { return nil }
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2.5, 2500 / max(bounds.width, bounds.height, 1))
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let text = recognizedText(in: image)
            else { continue }
            pages.append(text)
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n")
    }

    static func recognizedText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Metadata

    /// One searchable line describing the file: owner, group and permissions for anything; camera,
    /// lens, date taken and size for photos; artist, album, title, genre and year for music.
    static func metadataText(of url: URL) -> String? {
        var parts: [String] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let owner = attributes[.ownerAccountName] as? String { parts.append("owner \(owner)") }
            if let group = attributes[.groupOwnerAccountName] as? String { parts.append("group \(group)") }
            if let mode = attributes[.posixPermissions] as? Int { parts.append(permissions(mode)) }
        }
        // The stat above reads no file data; the headers below do, and reading an iCloud
        // placeholder downloads it — a Metadata search would pull down every evicted photo and song.
        if !SearchEngine.isPlaceholder(url) {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true { parts += imageMetadata(of: url) }
            if type?.conforms(to: .audio) == true { parts += audioMetadata(of: url) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `ls -l` style: 0o644 → "rw-r--r--".
    static func permissions(_ mode: Int) -> String {
        let symbols: [Character] = ["r", "w", "x"]
        return String((0..<9).map { bit in
            mode & (1 << (8 - bit)) != 0 ? symbols[bit % 3] : "-"
        })
    }

    static func imageMetadata(of url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var parts: [String] = []
        for value in [tiff?[kCGImagePropertyTIFFMake], tiff?[kCGImagePropertyTIFFModel], exif?[kCGImagePropertyExifLensModel]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty { parts.append(text) }
        }
        // EXIF writes dates as "2024:05:01 10:30:00"; the colons in the date make it unsearchable
        // as a date, so it is rewritten "2024-05-01 10:30".
        if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, taken.count >= 16 {
            parts.append("taken " + taken.prefix(10).replacingOccurrences(of: ":", with: "-") + " " + taken.dropFirst(11).prefix(5))
        }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int
        {
            parts.append("\(width)×\(height)")
        }
        return parts
    }

    static func audioMetadata(of url: URL) -> [String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [] }
        defer { AudioFileClose(file) }
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let dictionary = info?.takeRetainedValue() as? [String: Any]
        else { return [] }
        let keys = [
            kAFInfoDictionary_Artist, kAFInfoDictionary_Album, kAFInfoDictionary_Title,
            kAFInfoDictionary_Genre, kAFInfoDictionary_Year, kAFInfoDictionary_Composer,
        ]
        return keys.compactMap { key in
            (dictionary[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
