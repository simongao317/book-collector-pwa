import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let storageKey = "book-collector-library-v1"

    init() {
        load()
        migrateImportedCoverDataToURLs()
        cleanupExpiredPendingBooks()
    }

    func add(_ newBook: Book) throws {
        var book = newBook
        book.normalizeIdentifiers()
        try validate(book)
        books.insert(book, at: 0)
        save()
    }

    func update(_ book: Book) throws {
        var updated = book
        updated.normalizeIdentifiers()
        try validate(updated)
        guard let index = books.firstIndex(where: { $0.id == updated.id }) else { return }
        books[index] = updated
        save()
    }

    func delete(at offsets: IndexSet, in filteredBooks: [Book]) {
        let ids = offsets.map { filteredBooks[$0].id }
        books.removeAll { ids.contains($0.id) }
        save()
    }

    func setOwnership(_ status: OwnershipStatus, for book: Book) throws {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        guard books[index].ownershipStatus != status else { return }
        if status == .wishlist {
            books[index].ownershipStatus = .wishlist
            books[index].wishlistReadingStatus = .wantToRead
            books[index].pendingSince = nil
        } else {
            if books[index].entrySource == .manual, books[index].coverPhotoData == nil {
                throw LibraryError.ownedManualNeedsPhoto
            }
            books[index].ownershipStatus = .owned
            books[index].ownedReadingStatus = .unread
            books[index].pendingSince = nil
        }
        books[index].normalizeIdentifiers()
        save()
    }

    func setOwnedReadingStatus(_ status: OwnedReadingStatus, for book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].ownershipStatus = .owned
        books[index].ownedReadingStatus = status
        books[index].pendingSince = nil
        books[index].normalizeIdentifiers()
        save()
    }

    func setWishlistReadingStatus(_ status: WishlistReadingStatus, for book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].ownershipStatus = .wishlist
        books[index].wishlistReadingStatus = status
        books[index].normalizeIdentifiers()
        save()
    }

    func importBooks(_ importedBooks: [Book]) throws {
        var next = books
        for original in importedBooks {
            var book = original
            book.normalizeIdentifiers()
            if let duplicateIndex = next.firstIndex(where: { isSameBook($0, book) }) {
                if next[duplicateIndex].ownershipStatus == .owned, book.ownershipStatus == .wishlist {
                    continue
                }
                book.id = next[duplicateIndex].id
                try validate(book, within: next)
                next[duplicateIndex] = book
            } else {
                try validate(book, within: next)
                next.insert(book, at: 0)
            }
        }
        books = next
        save()
    }

    func mergeImportedBook(_ imported: Book) throws {
        var book = imported
        book.normalizeIdentifiers()
        if let index = books.firstIndex(where: { isSameBook($0, book) }) {
            if books[index].ownershipStatus == .owned, book.ownershipStatus == .wishlist {
                return
            }
            book.id = books[index].id
            try validate(book)
            books[index] = book
        } else {
            try validate(book)
            books.insert(book, at: 0)
        }
        save()
    }

    func mergeImportedBooks(_ importedBooks: [Book]) throws {
        var next = books
        for original in importedBooks {
            var book = original
            book.normalizeIdentifiers()
            if let index = next.firstIndex(where: { isSameBook($0, book) }) {
                if next[index].ownershipStatus == .owned, book.ownershipStatus == .wishlist {
                    continue
                }
                book.id = next[index].id
                try validate(book, within: next)
                next[index] = book
            } else {
                try validate(book, within: next)
                next.insert(book, at: 0)
            }
        }
        books = next
        save()
    }

    func hasOwnedVersion(of book: Book) -> Bool {
        books.contains { other in
            other.id != book.id &&
            other.ownershipStatus == .owned &&
            isSameBook(other, book)
        }
    }

    func cleanupExpiredPendingBooks() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let originalCount = books.count
        books.removeAll { book in
            book.ownershipStatus == .wishlist &&
            book.wishlistReadingStatus == .pending &&
            (book.pendingSince ?? book.createdAt) < cutoff
        }
        if books.count != originalCount {
            save()
        }
    }

    func validate(_ book: Book) throws {
        try validate(book, within: books)
    }

    private func validate(_ book: Book, within collection: [Book]) throws {
        let identifier = book.primaryIdentifier
        guard !identifier.isEmpty else {
            throw LibraryError.missingIdentifier
        }

        let duplicate = collection.contains { other in
            other.id != book.id &&
            other.identifierKind == book.identifierKind &&
            other.primaryIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
        }
        if duplicate {
            throw LibraryError.duplicateIdentifier(identifier)
        }

        if book.ownershipStatus == .owned,
           book.entrySource == .manual,
           book.coverPhotoData == nil {
            throw LibraryError.ownedManualNeedsPhoto
        }
    }

    private func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        if !lhs.primaryIdentifier.isEmpty,
           lhs.identifierKind == rhs.identifierKind,
           lhs.primaryIdentifier.caseInsensitiveCompare(rhs.primaryIdentifier) == .orderedSame {
            return true
        }
        if let leftID = lhs.doubanSubjectID?.trimmed, !leftID.isEmpty,
           let rightID = rhs.doubanSubjectID?.trimmed, !rightID.isEmpty,
           leftID == rightID {
            return true
        }
        return !lhs.title.trimmed.isEmpty &&
            lhs.title.trimmed.caseInsensitiveCompare(rhs.title.trimmed) == .orderedSame
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        books = (try? JSONDecoder().decode([Book].self, from: data)) ?? []
    }

    private func migrateImportedCoverDataToURLs() {
        var changed = false
        for index in books.indices {
            if books[index].entrySource == .csv,
               !(books[index].coverURL ?? "").trimmed.isEmpty,
               books[index].coverPhotoData != nil {
                books[index].coverPhotoData = nil
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum LibraryError: LocalizedError {
    case missingIdentifier
    case duplicateIdentifier(String)
    case ownedManualNeedsPhoto

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            return "必须填写 ISBN、统一书号或自定义书号之一。"
        case .duplicateIdentifier(let identifier):
            return "书号“\(identifier)”已经存在，不能重复录入。"
        case .ownedManualNeedsPhoto:
            return "手写导入已买图书时，需要拍摄或选择一张封面照片。"
        }
    }
}
