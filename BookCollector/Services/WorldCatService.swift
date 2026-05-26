import Foundation

struct BookLookupCandidate: Identifiable, Equatable {
    var id = UUID()
    var sourceName: String
    var sourceURL: URL
    var book: Book
    var note: String = ""
    var isFallback: Bool = false
    var canSelect: Bool = true
}

struct WorldCatService {
    func enrichDoubanExportedBook(_ input: Book) async throws -> Book {
        guard let urlString = input.doubanSubjectURL,
              let url = URL(string: urlString) else {
            return try await enrichImportedBookFromISBN(input)
        }

        let html = try await fetchHTML(from: url)
        var book = input
        let isbn = Self.normalizedISBN(firstNonEmpty([
            extractMeta("book:isbn", from: html),
            extractDoubanDetail(label: "ISBN", from: html)
        ]))
        if !isbn.isEmpty {
            book.identifierKind = .isbn
            book.isbn = isbn
            book.customNumber = input.customNumber
        }

        if book.title.trimmed.isEmpty {
            book.title = cleanTitle(firstNonEmpty([
                extractMeta("og:title", from: html),
                extractTitleTag(from: html),
                extractHeading(from: html)
            ]))
        }
        if book.authors.trimmed.isEmpty {
            book.authors = extractMeta("book:author", from: html)
        }
        let cover = firstNonEmpty([
            extractMeta("og:image", from: html),
            book.coverURL ?? ""
        ])
        book.coverURL = cover
        book.normalizeIdentifiers()
        return book
    }

    private func enrichCoverOnly(_ input: Book) async throws -> Book {
        var book = input
        book.normalizeIdentifiers()
        return book
    }

    private func enrichImportedBookFromISBN(_ input: Book) async throws -> Book {
        let isbn = Self.normalizedISBN(firstNonEmpty([
            input.isbn,
            input.identifierKind == .isbn ? input.identifier : ""
        ]))
        guard !isbn.isEmpty else {
            return try await enrichCoverOnly(input)
        }

        let found = try await lookupDoubanMetadata(isbn: isbn, downloadCover: false)
        var book = input
        book.identifierKind = .isbn
        book.isbn = isbn
        if book.title.trimmed.isEmpty {
            book.title = found.title
        }
        if book.originalTitle.trimmed.isEmpty {
            book.originalTitle = found.originalTitle
        }
        if book.seriesTitle.trimmed.isEmpty {
            book.seriesTitle = found.seriesTitle
        }
        if book.authors.trimmed.isEmpty {
            book.authors = found.authors
        }
        if book.publisher.trimmed.isEmpty {
            book.publisher = found.publisher
        }
        if book.publicationDate.trimmed.isEmpty {
            book.publicationDate = found.publicationDate
        }
        if (book.coverURL ?? "").trimmed.isEmpty {
            book.coverURL = found.coverURL
        }
        book.coverPhotoData = nil
        book.normalizeIdentifiers()
        return book
    }

    func lookup(isbn: String) async throws -> Book {
        let normalizedISBN = Self.normalizedISBN(isbn)
        guard !normalizedISBN.isEmpty else {
            throw WorldCatError.invalidISBN
        }
        let book = try await lookupDouban(isbn: normalizedISBN)
        guard isUsefulResult(book, isbn: normalizedISBN) else {
            throw WorldCatError.noResult(Self.searchURL(isbn: normalizedISBN))
        }
        return book
    }

    func lookupCandidates(isbn: String) async throws -> [BookLookupCandidate] {
        let normalizedISBN = Self.normalizedISBN(isbn)
        guard !normalizedISBN.isEmpty else {
            throw WorldCatError.invalidISBN
        }

        let attempts: [(String, URL, () async throws -> Book)] = [
            ("豆瓣图书", Self.doubanURL(isbn: normalizedISBN), { try await lookupDouban(isbn: normalizedISBN) }),
            ("ISBN Search", Self.isbnSearchURL(isbn: normalizedISBN), { try await lookupISBNSearch(isbn: normalizedISBN) }),
            ("DirectTextbook", Self.directTextbookURL(isbn: normalizedISBN), { try await lookupDirectTextbook(isbn: normalizedISBN) }),
            ("Open Library", Self.openLibraryURL(isbn: normalizedISBN), { try await lookupOpenLibrary(isbn: normalizedISBN) }),
            ("Google Books", Self.googleBooksURL(isbn: normalizedISBN), { try await lookupGoogleBooks(isbn: normalizedISBN) })
        ]

        var candidates: [BookLookupCandidate] = []
        for attempt in attempts {
            do {
                let book = try await attempt.2()
                guard isUsefulResult(book, isbn: normalizedISBN) else { continue }
                candidates.append(BookLookupCandidate(sourceName: attempt.0, sourceURL: attempt.1, book: book))
            } catch {
                candidates.append(failureCandidate(sourceName: attempt.0, sourceURL: attempt.1, isbn: normalizedISBN, error: error))
            }
        }

        candidates.append(fallbackCandidate(isbn: normalizedISBN))
        return candidates
    }

    private func lookupDouban(isbn: String) async throws -> Book {
        try await lookupDoubanMetadata(isbn: isbn, downloadCover: true)
    }

    private func lookupDoubanMetadata(isbn: String, downloadCover: Bool) async throws -> Book {
        let lookupURL = Self.doubanURL(isbn: isbn)
        let html = try await fetchHTML(from: lookupURL)

        var book = baseBook(isbn: isbn)
        book.title = cleanTitle(firstNonEmpty([
            extractMetaContent(named: "og:title", from: html),
            extractTitleTag(from: html),
            extractHeading(from: html)
        ]))
        book.originalTitle = extractDoubanDetail(label: "原作名", from: html)
        book.seriesTitle = extractDoubanDetail(label: "丛书", from: html)
        book.authors = firstNonEmpty([
            extractMetaContent(named: "book:author", from: html),
            extractDoubanDetail(label: "作者", from: html),
            extractDoubanDetail(label: "作者:", from: html)
        ])
        book.publisher = extractDoubanDetail(label: "出版社", from: html)
        book.publicationDate = extractDoubanDetail(label: "出版年", from: html)
        if let coverURL = extractCoverURL(from: html, baseURL: lookupURL, isbn: isbn) {
            book.coverURL = coverURL.absoluteString
            if downloadCover {
                book.coverPhotoData = try? await downloadImage(from: coverURL)
            }
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupISBNSearch(isbn: String) async throws -> Book {
        let lookupURL = Self.isbnSearchURL(isbn: isbn)
        let html = try await fetchHTML(from: lookupURL)

        var book = baseBook(isbn: isbn)
        book.title = cleanTitle(firstNonEmpty([
            extractMetaContent(named: "og:title", from: html),
            extractTitleTag(from: html),
            extractHeading(from: html)
        ]))
        book.authors = extractDetail(label: "Author", from: html)
        book.publisher = extractDetail(label: "Publisher", from: html)
        book.publicationDate = firstNonEmpty([
            extractDetail(label: "Published", from: html),
            extractDetail(label: "Publication Date", from: html),
            extractDetail(label: "Date Published", from: html)
        ])
        if let coverURL = extractCoverURL(from: html, baseURL: lookupURL, isbn: isbn) {
            book.coverURL = coverURL.absoluteString
            book.coverPhotoData = try? await downloadImage(from: coverURL)
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupISBNDB(isbn: String) async throws -> Book {
        let lookupURL = Self.isbnDBURL(isbn: isbn)
        let html = try await fetchHTML(from: lookupURL)

        var book = baseBook(isbn: isbn)
        book.title = cleanTitle(firstNonEmpty([
            extractMetaContent(named: "og:title", from: html),
            extractTitleTag(from: html),
            extractHeading(from: html)
        ]))
        book.authors = firstNonEmpty([
            extractDetail(label: "Author", from: html),
            extractDetail(label: "Authors", from: html)
        ])
        book.publisher = extractDetail(label: "Publisher", from: html)
        book.publicationDate = firstNonEmpty([
            extractDetail(label: "Published", from: html),
            extractDetail(label: "Publish Date", from: html),
            extractDetail(label: "Publication Date", from: html)
        ])
        if let coverURL = extractCoverURL(from: html, baseURL: lookupURL, isbn: isbn) {
            book.coverURL = coverURL.absoluteString
            book.coverPhotoData = try? await downloadImage(from: coverURL)
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupBioRegistry(isbn: String) async throws -> Book {
        let lookupURL = Self.bioRegistryURL(isbn: isbn)
        let html = try await fetchHTML(from: lookupURL)

        var book = baseBook(isbn: isbn)
        book.title = cleanTitle(firstNonEmpty([
            extractMetaContent(named: "og:title", from: html),
            extractTitleTag(from: html),
            extractHeading(from: html)
        ]))
        book.authors = firstNonEmpty([
            extractDetail(label: "Author", from: html),
            extractDetail(label: "Authors", from: html)
        ])
        book.publisher = extractDetail(label: "Publisher", from: html)
        book.publicationDate = firstNonEmpty([
            extractDetail(label: "Published", from: html),
            extractDetail(label: "Publication Date", from: html)
        ])
        if let coverURL = extractCoverURL(from: html, baseURL: lookupURL, isbn: isbn) {
            book.coverURL = coverURL.absoluteString
            book.coverPhotoData = try? await downloadImage(from: coverURL)
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupDirectTextbook(isbn: String) async throws -> Book {
        let lookupURL = Self.directTextbookURL(isbn: isbn)
        let html = try await fetchHTML(from: lookupURL)

        var book = baseBook(isbn: isbn)
        let description = extractMetaContent(named: "description", from: html)
        book.title = cleanTitle(firstNonEmpty([
            extractDirectTextbookTitle(from: html, isbn: isbn),
            extractTitleTag(from: html)
        ]))
        book.authors = extractDirectTextbookAuthor(from: description)
        if let coverURL = extractCoverURL(from: html, baseURL: lookupURL, isbn: isbn) {
            book.coverURL = coverURL.absoluteString
            book.coverPhotoData = try? await downloadImage(from: coverURL)
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupOpenLibrary(isbn: String) async throws -> Book {
        let lookupURL = Self.openLibraryURL(isbn: isbn)
        let data = try await fetchData(from: lookupURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["ISBN:\(isbn)"] as? [String: Any] else {
            throw WorldCatError.noResult(lookupURL)
        }

        var book = baseBook(isbn: isbn)
        book.title = payload["title"] as? String ?? ""
        if let authors = payload["authors"] as? [[String: Any]] {
            book.authors = authors.compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        if let publishers = payload["publishers"] as? [[String: Any]] {
            book.publisher = publishers.compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        book.publicationDate = payload["publish_date"] as? String ?? ""
        if let cover = payload["cover"] as? [String: Any],
           let coverString = firstNonEmpty([
            cover["large"] as? String ?? "",
            cover["medium"] as? String ?? "",
            cover["small"] as? String ?? ""
           ]) as String?,
           let coverURL = URL(string: coverString) {
            book.coverURL = coverURL.absoluteString
            book.coverPhotoData = try? await downloadImage(from: coverURL)
        }
        book.normalizeIdentifiers()
        return book
    }

    private func lookupGoogleBooks(isbn: String) async throws -> Book {
        let lookupURL = Self.googleBooksURL(isbn: isbn)
        let data = try await fetchData(from: lookupURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]],
              let volumeInfo = items.first?["volumeInfo"] as? [String: Any] else {
            throw WorldCatError.noResult(lookupURL)
        }

        var book = baseBook(isbn: isbn)
        book.title = volumeInfo["title"] as? String ?? ""
        book.originalTitle = volumeInfo["subtitle"] as? String ?? ""
        if let authors = volumeInfo["authors"] as? [String] {
            book.authors = authors.joined(separator: ", ")
        }
        book.publisher = volumeInfo["publisher"] as? String ?? ""
        book.publicationDate = volumeInfo["publishedDate"] as? String ?? ""
        if let imageLinks = volumeInfo["imageLinks"] as? [String: Any] {
            let coverString = firstNonEmpty([
                imageLinks["extraLarge"] as? String ?? "",
                imageLinks["large"] as? String ?? "",
                imageLinks["medium"] as? String ?? "",
                imageLinks["thumbnail"] as? String ?? "",
                imageLinks["smallThumbnail"] as? String ?? ""
            ]).replacingOccurrences(of: "http://", with: "https://")
            if let coverURL = URL(string: coverString) {
                book.coverURL = coverURL.absoluteString
                book.coverPhotoData = try? await downloadImage(from: coverURL)
            }
        }
        book.normalizeIdentifiers()
        return book
    }

    static func searchURL(isbn: String) -> URL {
        doubanURL(isbn: isbn)
    }

    private static func normalizedISBN(_ isbn: String) -> String {
        isbn.uppercased().filter { $0.isNumber || $0 == "X" }
    }

    private static func isbnSearchURL(isbn: String) -> URL {
        URL(string: "https://isbnsearch.org/isbn/\(isbn)")!
    }

    private static func doubanURL(isbn: String) -> URL {
        URL(string: "https://book.douban.com/isbn/\(isbn)/")!
    }

    private static func isbnDBURL(isbn: String) -> URL {
        URL(string: "https://isbndb.com/book/\(isbn)")!
    }

    private static func openLibraryURL(isbn: String) -> URL {
        URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data")!
    }

    private static func directTextbookURL(isbn: String) -> URL {
        URL(string: "https://www.directtextbook.com/isbn/\(isbn)")!
    }

    private static func googleBooksURL(isbn: String) -> URL {
        URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)")!
    }

    private static func bioRegistryURL(isbn: String) -> URL {
        URL(string: "https://bioregistry.io/isbn:\(isbn)")!
    }

    private func fetchHTML(from url: URL) async throws -> String {
        let data = try await fetchData(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw WorldCatError.offline(url)
        } catch {
            throw WorldCatError.network(error.localizedDescription, url)
        }
        try validate(response)
        return data
    }

    private func baseBook(isbn: String) -> Book {
        var book = Book()
        book.identifierKind = .isbn
        book.isbn = isbn
        book.entrySource = .scan
        return book
    }

    private func fallbackCandidate(isbn: String) -> BookLookupCandidate {
        var book = baseBook(isbn: isbn)
        book.title = "ISBN \(isbn)"
        book.normalizeIdentifiers()
        return BookLookupCandidate(
            sourceName: "仅保存 ISBN",
            sourceURL: Self.searchURL(isbn: isbn),
            book: book,
            note: "没有使用网站补全信息，可以之后手动编辑。",
            isFallback: true
        )
    }

    private func failureCandidate(sourceName: String, sourceURL: URL, isbn: String, error: Error) -> BookLookupCandidate {
        var book = baseBook(isbn: isbn)
        book.title = "\(sourceName) 未查到"
        book.normalizeIdentifiers()
        return BookLookupCandidate(
            sourceName: sourceName,
            sourceURL: sourceURL,
            book: book,
            note: error.localizedDescription,
            isFallback: true,
            canSelect: false
        )
    }

    private func isUsefulResult(_ book: Book, isbn: String) -> Bool {
        let title = book.title.trimmed
        guard !title.isEmpty else { return false }
        let lowercased = title.lowercased()
        let rejectedTitles = [
            "isbn",
            "international standard book number",
            "bioregistry",
            "the bioregistry",
            "isbn search",
            "豆瓣"
        ]
        guard !rejectedTitles.contains(lowercased) else { return false }
        guard title != isbn, title != "ISBN \(isbn)" else { return false }
        return true
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WorldCatError.httpFailure
        }
    }

    private func extractMeta(_ property: String, from html: String) -> String {
        let pattern = "<meta[^>]+property=[\"']\(property)[\"'][^>]+content=[\"']([^\"']+)[\"'][^>]*>"
        return firstMatch(pattern, in: html)
    }

    private func extractMetaContent(named name: String, from html: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"'][^>]*>",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]*>"
        ]
        return firstNonEmpty(patterns.map { firstMatch($0, in: html) })
    }

    private func extractTitleTag(from html: String) -> String {
        firstMatch("<title>([^<]+)</title>", in: html)
    }

    private func extractHeading(from html: String) -> String {
        firstMatch("<h1[^>]*>(.*?)</h1>", in: html)
    }

    private func extractDetail(label: String, from html: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let patterns = [
            "<strong>\\s*\(escaped):?\\s*</strong>\\s*([^<]+)",
            "<b>\\s*\(escaped):?\\s*</b>\\s*([^<]+)",
            "\(escaped):\\s*</[^>]+>\\s*<[^>]+>\\s*([^<]+)",
            "\(escaped):\\s*([^<\\n]+)"
        ]
        for pattern in patterns {
            let value = firstMatch(pattern, in: html)
            if !value.trimmed.isEmpty {
                return cleanHTML(value)
            }
        }
        return ""
    }

    private func cleanTitle(_ title: String) -> String {
        var cleaned = title
            .replacingOccurrences(of: " - ISBN Search", with: "")
            .replacingOccurrences(of: " | ISBN Search", with: "")
            .replacingOccurrences(of: "ISBN Search", with: "")
            .replacingOccurrences(of: " | ISBNdb", with: "")
            .replacingOccurrences(of: " - ISBNdb", with: "")
            .replacingOccurrences(of: "ISBNdb", with: "")
            .replacingOccurrences(of: " | BioRegistry", with: "")
            .replacingOccurrences(of: " - BioRegistry", with: "")
            .replacingOccurrences(of: " (豆瓣)", with: "")
            .replacingOccurrences(of: "(豆瓣)", with: "")
            .replacingOccurrences(of: " | 豆瓣", with: "")
            .replacingOccurrences(of: " - 豆瓣", with: "")
            .replacingOccurrences(of: #"^\s*(?:ISBN\s*)?\d{9,13}[Xx]?\s*[-:：]\s*"#, with: "", options: .regularExpression)
            .trimmed
        if let dashRange = cleaned.range(of: " - "),
           cleaned[..<dashRange.lowerBound].allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "X" || $0 == "x" }) {
            cleaned = String(cleaned[dashRange.upperBound...]).trimmed
        }
        return cleaned
    }

    private func extractDoubanDetail(label: String, from html: String) -> String {
        let cleanLabel = label.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "：", with: "")
        let escaped = NSRegularExpression.escapedPattern(for: cleanLabel)
        let patterns = [
            #"<span[^>]+class=["']pl["'][^>]*>\s*"# + escaped + #"\s*:?\s*</span>\s*:?\s*(.*?)<br"#,
            #"<span[^>]+class=["']pl["'][^>]*>\s*"# + escaped + #"\s*：?\s*</span>\s*：?\s*(.*?)<br"#,
            escaped + #"\s*[:：]\s*([^<\n]+)"#
        ]
        for pattern in patterns {
            let value = firstMatch(pattern, in: html)
            if !value.trimmed.isEmpty {
                return cleanHTML(value)
            }
        }
        return ""
    }

    private func extractDirectTextbookTitle(from html: String, isbn: String) -> String {
        let patterns = [
            #"ISBN\s+"# + NSRegularExpression.escapedPattern(for: isbn) + #"\s*-\s*(.*?)\s+Direct Textbook"#,
            #"Find\s+"# + NSRegularExpression.escapedPattern(for: isbn) + #"\s+(.*?)\s+by\s+"#
        ]
        for pattern in patterns {
            let value = firstMatch(pattern, in: html)
            if !value.trimmed.isEmpty {
                return value
            }
        }
        return ""
    }

    private func extractDirectTextbookAuthor(from description: String) -> String {
        firstMatch(#"\s+by\s+(.+?)\s+at\s+over"#, in: description)
    }

    private func extractCoverURL(from html: String, baseURL: URL, isbn: String) -> URL? {
        let candidates = [
            extractMetaContent(named: "og:image", from: html),
            extractMetaContent(named: "twitter:image", from: html),
            firstMatch(#"<img[^>]+(?:id|class)=["'][^"']*(?:cover|book)[^"']*["'][^>]+src=["']([^"']+)["']"#, in: html),
            firstMatch(#"<img[^>]+src=["']([^"']+)["'][^>]+(?:id|class)=["'][^"']*(?:cover|book)[^"']*["']"#, in: html),
            firstMatch(#"<img[^>]+src=["']([^"']*isbndb[^"']*)["']"#, in: html),
            constructedISBNDBCoverURL(isbn: isbn)?.absoluteString ?? ""
        ]

        for candidate in candidates where !candidate.trimmed.isEmpty {
            if let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL,
               ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        return nil
    }

    private func constructedISBNDBCoverURL(isbn: String) -> URL? {
        let cleaned = isbn.uppercased().filter { $0.isNumber || $0 == "X" }
        guard cleaned.count >= 4 else { return nil }
        let suffix = String(cleaned.suffix(4))
        let first = String(suffix.prefix(2))
        let second = String(suffix.suffix(2))
        return URL(string: "https://images.isbndb.com/covers/\(first)/\(second)/\(cleaned).jpg")
    }

    private func downloadImage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://book.douban.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard !data.isEmpty,
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("image") == true else {
            throw WorldCatError.httpFailure
        }
        return data
    }

    private func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.trimmed.isEmpty } ?? ""
    }

    private func firstMatch(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return ""
        }
        return cleanHTML(String(text[captureRange]))
    }

    private func cleanHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }
}

enum WorldCatError: LocalizedError {
    case invalidISBN
    case offline(URL)
    case network(String, URL)
    case httpFailure
    case noResult(URL)

    var errorDescription: String? {
        switch self {
        case .invalidISBN:
            return "ISBN 不正确，无法检索。"
        case .offline(let url):
            return "手机提示当前 App 无法联网。请检查 BookCollector 的蜂窝数据/WLAN 权限。豆瓣图书页面：\(url.absoluteString)"
        case .network(let message, let url):
            return "\(message)\n豆瓣图书页面：\(url.absoluteString)"
        case .httpFailure:
            return "豆瓣图书返回异常，暂时无法读取图书信息。"
        case .noResult(let url):
            return "豆瓣图书页面没有返回可解析的书名。可以先手动补全，或用 Safari 打开核对：\(url.absoluteString)"
        }
    }
}
