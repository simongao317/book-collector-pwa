import Foundation

enum IdentifierKind: String, Codable, CaseIterable, Identifiable {
    case isbn = "ISBN"
    case unifiedNumber = "统一书号"
    case custom = "自定义书号"

    var id: String { rawValue }
}

enum OwnershipStatus: String, Codable, CaseIterable, Identifiable {
    case owned = "已买"
    case wishlist = "未买"

    var id: String { rawValue }
}

enum OwnedReadingStatus: String, Codable, CaseIterable, Identifiable {
    case read = "已读"
    case unread = "未读"

    var id: String { rawValue }
}

enum WishlistReadingStatus: String, Codable, CaseIterable, Identifiable {
    case read = "已读"
    case wantToRead = "想读"
    case pending = "待定"

    var id: String { rawValue }
}

enum EntrySource: String, Codable, CaseIterable, Identifiable {
    case csv = "CSV/Excel导入"
    case scan = "扫码导入"
    case manual = "手写导入"

    var id: String { rawValue }
}

struct Book: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var identifierKind: IdentifierKind = .isbn
    var identifier: String = ""
    var isbn: String = ""
    var unifiedNumber: String = ""
    var customNumber: String = ""
    var title: String = ""
    var originalTitle: String = ""
    var seriesTitle: String = ""
    var authors: String = ""
    var authorNationality: String = ""
    var publicationDate: String = ""
    var publisher: String = ""
    var ownershipStatus: OwnershipStatus = .owned
    var ownedReadingStatus: OwnedReadingStatus = .unread
    var wishlistReadingStatus: WishlistReadingStatus = .wantToRead
    var entrySource: EntrySource = .manual
    var coverPhotoData: Data?
    var createdAt: Date = Date()
    var pendingSince: Date?
    var categoryDate: Date?
    var doubanSubjectID: String?
    var doubanSubjectURL: String?
    var coverURL: String?

    var primaryIdentifier: String {
        switch identifierKind {
        case .isbn:
            return isbn.trimmed.isEmpty ? identifier.trimmed : isbn.trimmed
        case .unifiedNumber:
            return unifiedNumber.trimmed.isEmpty ? identifier.trimmed : unifiedNumber.trimmed
        case .custom:
            return customNumber.trimmed.isEmpty ? identifier.trimmed : customNumber.trimmed
        }
    }

    var displayTag: String {
        switch ownershipStatus {
        case .owned:
            return ownedReadingStatus.rawValue
        case .wishlist:
            return wishlistReadingStatus.rawValue
        }
    }

    var addedDateText: String {
        Self.shortDateFormatter.string(from: createdAt)
    }

    var categoryDateText: String {
        Self.shortDateFormatter.string(from: categoryDate ?? createdAt)
    }

    var sortDate: Date {
        categoryDate ?? createdAt
    }

    var pendingDaysRemaining: Int? {
        guard ownershipStatus == .wishlist, wishlistReadingStatus == .pending else { return nil }
        let start = pendingSince ?? createdAt
        let expiry = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return max(days, 0)
    }

    mutating func normalizeIdentifiers() {
        if identifierKind == .isbn {
            isbn = isbn.uppercased().filter { $0.isNumber || $0 == "X" }
        }
        let value = primaryIdentifier
        identifier = value
        switch identifierKind {
        case .isbn:
            isbn = value
        case .unifiedNumber:
            unifiedNumber = value
        case .custom:
            customNumber = value
        }
        if ownershipStatus == .wishlist, wishlistReadingStatus == .pending, pendingSince == nil {
            pendingSince = Date()
        }
        if wishlistReadingStatus != .pending {
            pendingSince = nil
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy.MM.dd"
        return formatter
    }()
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
