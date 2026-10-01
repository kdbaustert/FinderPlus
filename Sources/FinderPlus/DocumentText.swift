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
    /// members that hold their text; `unzip` matches the patterns itself, across folders.
    static func zipMembers(forExtension ext: String) -> [String]? {
        switch ext {
        case "xlsx", "xlsm": ["xl/sharedStrings.xml", "xl/worksheets/*.xml"]
        case "pptx": ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"]
        case "ods", "odp", "odg": ["content.xml"]
        case "epub": ["*.xhtml", "*.html", "*.htm"]
        default: nil
        }
    }

    /// Streams the members out with `unzip -p`, stopping once `maxBytes` have been read, and
    /// returns their text without markup.
    static func zipText(
        of url: URL, members: [String], maxBytes: Int, isStopped: () -> Bool = { Task.isCancelled }
    ) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + members
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        while data.count < maxBytes, !isStopped(),
              let chunk = try? output.fileHandleForReading.read(upToCount: 1 << 16), !chunk.isEmpty
        {
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard !data.isEmpty, !isStopped() else { return nil }
        return markupText(String(decoding: data, as: UTF8.self))
    }

    /// Text from HTML or XML. Tags become spaces, so neighbouring runs of text ("<a:t>Q3</a:t>
    /// <a:t>report</a:t>") do not fuse into one word; scripts and styles are dropped entirely.
    static func markupText(_ markup: String) -> String {
        var text = markup.replacing(/<(script|style)\b[\s\S]*?<\/\1>/.ignoresCase(), with: " ")
        text = text.replacing(/<[^>]*>/, with: " ")
        // One pass, so "&amp;lt;" decodes to "&lt;" and no further. An unknown name is left as
        // written.
        text = text.replacing(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/) { match in
            let body = match.output.1
            let scalar: Unicode.Scalar? = if body.hasPrefix("#x") || body.hasPrefix("#X") {
                UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if body.hasPrefix("#") {
                UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init)
            } else {
                namedEntities[String(body)]
            }
            guard let scalar, scalar != "\0" else { return String(match.output.0) }
            return String(Character(scalar))
        }
        return text.replacing(/\s+/, with: " ")
    }

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
