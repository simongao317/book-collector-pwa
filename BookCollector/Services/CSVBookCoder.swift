import Foundation

enum CSVBookCoder {
    static let headers = [
        "书号类型",
        "ISBN",
        "统一书号",
        "自定义书号",
        "书名",
        "原名",
        "丛书名",
        "作者",
        "作者国籍",
        "出版时间",
        "出版社",
        "收藏状态",
        "已买阅读标签",
        "未买阅读标签",
        "录入方式",
        "封面链接"
    ]

    static func encode(_ books: [Book]) -> String {
        let rows = books.map { book in
            [
                book.identifierKind.rawValue,
                book.isbn,
                book.unifiedNumber,
                book.customNumber,
                book.title,
                book.originalTitle,
                book.seriesTitle,
                book.authors,
                book.authorNationality,
                book.publicationDate,
                book.publisher,
                book.ownershipStatus.rawValue,
                book.ownedReadingStatus.rawValue,
                book.wishlistReadingStatus.rawValue,
                book.entrySource.rawValue,
                book.coverURL ?? ""
            ].map(escape).joined(separator: ",")
        }
        return ([headers.map(escape).joined(separator: ",")] + rows).joined(separator: "\n")
    }

    static func decode(_ text: String) throws -> [Book] {
        let rows = parseRows(text)
        guard let header = rows.first else { return [] }
        let normalizedHeader = header.map { $0.trimmed }
        return rows.dropFirst().compactMap { row in
            guard !row.allSatisfy({ $0.trimmed.isEmpty }) else { return nil }
            var values: [String: String] = [:]
            for (index, key) in normalizedHeader.enumerated() where index < row.count {
                values[key] = row[index].trimmed
            }

            var book = Book()
            book.identifierKind = IdentifierKind(rawValue: values["书号类型"] ?? "") ?? .isbn
            book.isbn = values["ISBN"] ?? ""
            book.unifiedNumber = values["统一书号"] ?? ""
            book.customNumber = values["自定义书号"] ?? ""
            book.title = values["书名"] ?? ""
            book.originalTitle = values["原名"] ?? ""
            book.seriesTitle = values["丛书名"] ?? ""
            book.authors = values["作者"] ?? ""
            book.authorNationality = values["作者国籍"] ?? ""
            book.publicationDate = values["出版时间"] ?? ""
            book.publisher = values["出版社"] ?? ""
            book.ownershipStatus = OwnershipStatus(rawValue: values["收藏状态"] ?? "") ?? .owned
            book.ownedReadingStatus = OwnedReadingStatus(rawValue: values["已买阅读标签"] ?? "") ?? .unread
            book.wishlistReadingStatus = WishlistReadingStatus(rawValue: values["未买阅读标签"] ?? "") ?? .wantToRead
            book.entrySource = EntrySource(rawValue: values["录入方式"] ?? "") ?? .csv
            book.coverURL = firstNonEmpty([
                values["封面链接"] ?? "",
                values["cover_url"] ?? "",
                values["coverURL"] ?? "",
                values["cover"] ?? ""
            ])
            book.createdAt = Date()
            book.normalizeIdentifiers()
            return book
        }
    }

    private static func escape(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n")
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }

    private static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.trimmed.isEmpty } ?? ""
    }
}
