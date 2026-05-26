import Foundation
import zlib

enum XLSXBookCoder {
    static func decode(data: Data, fileName: String) throws -> [Book] {
        let archive = try ZipArchive(data: data)
        let sharedStrings = parseSharedStrings(archive.textFile(named: "xl/sharedStrings.xml") ?? "")
        guard let sheetXML = archive.textFile(named: "xl/worksheets/sheet1.xml") else {
            throw XLSXBookError.missingSheet
        }
        let rows = parseSheet(sheetXML, sharedStrings: sharedStrings)
        guard let header = rows.first?.values else { return [] }

        return rows.dropFirst().compactMap { row in
            var values: [String: String] = [:]
            var dates: [String: Date] = [:]
            for (index, key) in header.enumerated() where !key.trimmed.isEmpty {
                values[key] = index < row.values.count ? row.values[index].trimmed : ""
                dates[key] = row.dates[index]
            }
            guard !(values["title"] ?? "").trimmed.isEmpty else { return nil }
            return makeBook(values: values, dates: dates, fileName: fileName)
        }
    }

    private static func makeBook(values: [String: String], dates: [String: Date], fileName: String) -> Book {
        let subjectID = values["subject_id"] ?? ""
        let pubInfo = parsePub(values["pub"] ?? "")
        var book = Book()
        book.identifierKind = .custom
        book.customNumber = subjectID.trimmed.isEmpty ? UUID().uuidString : subjectID
        book.doubanSubjectID = subjectID
        book.doubanSubjectURL = values["subject_url"]
        book.coverURL = values["cover_url"]
        book.title = values["title"] ?? ""
        book.originalTitle = values["subtitle"] ?? ""
        book.authors = pubInfo.authors
        book.publisher = pubInfo.publisher
        book.publicationDate = pubInfo.publicationDate
        book.categoryDate = dates["date"] ?? parseDate(values["date"] ?? "")
        book.createdAt = book.categoryDate ?? Date()
        book.entrySource = .csv

        let status = values["status"] ?? ""
        if fileName.contains("已购") || fileName.contains("已买") {
            book.ownershipStatus = .owned
            book.ownedReadingStatus = status.contains("读") ? .read : .unread
        } else if fileName.contains("未购已读") || fileName.contains("未买已读") || status.contains("读过") {
            book.ownershipStatus = .wishlist
            book.wishlistReadingStatus = .read
        } else {
            book.ownershipStatus = .wishlist
            book.wishlistReadingStatus = .wantToRead
        }
        book.normalizeIdentifiers()
        return book
    }

    private static func parsePub(_ value: String) -> (authors: String, publisher: String, publicationDate: String) {
        let parts = value
            .components(separatedBy: " / ")
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return ("", "", "") }

        let dateIndex = parts.firstIndex { $0.range(of: #"^\d{4}([-.年]\d{1,2}.*)?$"#, options: .regularExpression) != nil }
        if let dateIndex {
            let publisher = dateIndex > 0 ? parts[dateIndex - 1] : ""
            let authors = dateIndex > 1 ? parts[..<(dateIndex - 1)].joined(separator: " / ") : ""
            return (authors, publisher, parts[dateIndex])
        }

        let publisher = parts.count >= 2 ? parts[parts.count - 2] : parts.last ?? ""
        let authors = parts.count >= 3 ? parts.dropLast(2).joined(separator: " / ") : ""
        return (authors, publisher, "")
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        matches(#"<si[^>]*>(.*?)</si>"#, in: xml).map { item in
            matches(#"<t[^>]*>(.*?)</t>"#, in: item)
                .map(cleanXML)
                .joined()
        }
    }

    private static func parseSheet(_ xml: String, sharedStrings: [String]) -> [(values: [String], dates: [Int: Date])] {
        matches(#"<row[^>]*>(.*?)</row>"#, in: xml).map { rowXML in
            var values: [String] = []
            var dates: [Int: Date] = [:]
            for cellXML in matches(#"<c\b[^>]*>.*?</c>"#, in: rowXML) {
                let ref = firstMatch(#"r="([A-Z]+)\d+""#, in: cellXML)
                let column = columnIndex(ref)
                while values.count <= column { values.append("") }

                let type = firstMatch(#"t="([^"]+)""#, in: cellXML)
                let raw = firstMatch(#"<v[^>]*>(.*?)</v>"#, in: cellXML)
                if type == "s", let index = Int(raw), sharedStrings.indices.contains(index) {
                    values[column] = sharedStrings[index]
                } else if type == "inlineStr" {
                    values[column] = cleanXML(firstMatch(#"<t[^>]*>(.*?)</t>"#, in: cellXML))
                } else {
                    values[column] = cleanXML(raw)
                    if let number = Double(raw), let date = excelDate(number) {
                        dates[column] = date
                    }
                }
            }
            return (values, dates)
        }
    }

    private static func columnIndex(_ letters: String) -> Int {
        var result = 0
        for scalar in letters.unicodeScalars {
            result = result * 26 + Int(scalar.value - 64)
        }
        return max(result - 1, 0)
    }

    private static func excelDate(_ serial: Double) -> Date? {
        guard serial > 20_000, serial < 80_000 else { return nil }
        return Date(timeIntervalSince1970: (serial - 25_569) * 86_400)
    }

    private static func parseDate(_ value: String) -> Date? {
        for format in ["yyyy-MM-dd", "yyyy/M/d", "yyyy-M-d", "yyyy年M月d日"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String {
        matches(pattern, in: text).first ?? ""
    }

    private static func cleanXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }
}

enum XLSXBookError: LocalizedError {
    case invalidArchive
    case unsupportedCompression
    case missingSheet

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "无法读取 XLSX 文件。"
        case .unsupportedCompression:
            return "这个 XLSX 的压缩格式暂不支持。"
        case .missingSheet:
            return "XLSX 中没有找到第一个工作表。"
        }
    }
}

private struct ZipArchive {
    private let data: Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readEntries(from: data)
    }

    func textFile(named name: String) -> String? {
        guard let entry = entries[name], let fileData = try? read(entry) else { return nil }
        return String(data: fileData, encoding: .utf8)
    }

    private func read(_ entry: Entry) throws -> Data {
        guard data.uint32(at: entry.localHeaderOffset) == 0x04034b50 else {
            throw XLSXBookError.invalidArchive
        }
        let nameLength = Int(data.uint16(at: entry.localHeaderOffset + 26))
        let extraLength = Int(data.uint16(at: entry.localHeaderOffset + 28))
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw XLSXBookError.unsupportedCompression
        }
    }

    private static func readEntries(from data: Data) throws -> [String: Entry] {
        guard let eocdOffset = data.lastOffset(of: 0x06054b50) else {
            throw XLSXBookError.invalidArchive
        }
        let entryCount = Int(data.uint16(at: eocdOffset + 10))
        var offset = Int(data.uint32(at: eocdOffset + 16))
        var entries: [String: Entry] = [:]

        for _ in 0..<entryCount {
            guard data.uint32(at: offset) == 0x02014b50 else {
                throw XLSXBookError.invalidArchive
            }
            let method = Int(data.uint16(at: offset + 10))
            let compressedSize = Int(data.uint32(at: offset + 20))
            let uncompressedSize = Int(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localHeaderOffset = Int(data.uint32(at: offset + 42))
            let nameStart = offset + 46
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""
            entries[name] = Entry(method: method, compressedSize: compressedSize, uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset)
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw XLSXBookError.unsupportedCompression }
        defer { inflateEnd(&stream) }

        let outputCapacity = max(expectedSize, 1)
        var output = Data(count: outputCapacity)
        let result: Int32 = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputRaw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outputRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw XLSXBookError.unsupportedCompression }
        output.count = Int(stream.total_out)
        return output
    }

    private struct Entry {
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    func lastOffset(of signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        var index = count - 4
        while index >= 0 {
            if uint32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }
}
