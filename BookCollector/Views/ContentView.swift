import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var searchText = ""
    @State private var selectedCategory: LibraryCategory = .owned
    @State private var ownedFilter: OwnedShelfFilter = .unread
    @State private var wantToReadFilter: WantToReadShelfFilter = .unpurchased
    @State private var sortOrder: TimeSortOrder = .descending
    @State private var addDraftBook = Book()
    @State private var showingAdd = false
    @State private var showingScanner = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var editingBook: Book?
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var offerManualInput = false
    @State private var isImporting = false
    @State private var importProgressText = ""
    @State private var lookupCandidates: [BookLookupCandidate] = []
    @State private var showingLookupResults = false

    private func filteredBooks(in snapshot: LibrarySnapshot) -> [Book] {
        let trimmedSearch = searchText.trimmed
        let visible = snapshot.books.filter { book in
            let matchesStatus = selectedCategory.matches(book, snapshot: snapshot) &&
                (selectedCategory != .owned || ownedFilter.matches(book)) &&
                (selectedCategory != .wantToRead || wantToReadFilter.matches(book))
            let haystack = [
                book.title,
                book.originalTitle,
                book.seriesTitle,
                book.authors,
                book.publisher,
                book.primaryIdentifier
            ].joined(separator: " ")
            let matchesSearch = trimmedSearch.isEmpty ||
                haystack.localizedCaseInsensitiveContains(trimmedSearch)
            return matchesStatus && matchesSearch
        }
        return visible.sorted { lhs, rhs in
            switch sortOrder {
            case .descending:
                return lhs.sortDate > rhs.sortDate
            case .ascending:
                return lhs.sortDate < rhs.sortDate
            }
        }
    }

    private var importTypes: [UTType] {
        [.commaSeparatedText, .plainText, UTType(filenameExtension: "xlsx")!]
    }

    var body: some View {
        let snapshot = LibrarySnapshot(books: store.books)
        let visibleBooks = filteredBooks(in: snapshot)

        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("藏书")
                    .font(.system(size: 48, weight: .black))
                    .padding(.horizontal, 18)
                    .padding(.top, -4)

                CategoryHeader(
                    selectedCategory: $selectedCategory,
                    ownedFilter: $ownedFilter,
                    wantToReadFilter: $wantToReadFilter,
                    sortOrder: $sortOrder,
                    snapshot: snapshot
                )

                List {
                    Section {
                        if isImporting {
                            ProgressView(importProgressText.isEmpty ? "正在导入..." : importProgressText)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if visibleBooks.isEmpty {
                            ContentUnavailableView("还没有图书", systemImage: "books.vertical", description: Text("可以扫码、CSV/XLSX 导入，或手写录入第一本书。"))
                        } else {
                            ForEach(visibleBooks) { book in
                                BookRow(
                                    book: book,
                                    category: selectedCategory,
                                    onEdit: { editingBook = book }
                                )
                            }
                            .onDelete { offsets in
                                store.delete(at: offsets, in: visibleBooks)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索书名、作者、书号")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("扫码", systemImage: "barcode.viewfinder")
                    }

                    Menu {
                        Button {
                            addDraftBook = Book()
                            showingAdd = true
                        } label: {
                            Label("手写录入", systemImage: "square.and.pencil")
                        }

                        Button {
                            showingImporter = true
                        } label: {
                            Label("导入 CSV/XLSX", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            showingExporter = true
                        } label: {
                            Label("导出 CSV", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                BookFormView(mode: .add(addDraftBook))
            }
            .sheet(item: $editingBook) { book in
                BookFormView(mode: .edit(book))
            }
            .sheet(isPresented: $showingScanner) {
                ScannerView { isbn in
                    showingScanner = false
                    Task {
                        await addScannedISBN(isbn)
                    }
                }
            }
            .sheet(isPresented: $showingLookupResults) {
                LookupResultsView(candidates: lookupCandidates) { candidate in
                    addLookupCandidate(candidate)
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importTypes) { result in
                Task {
                    await importFile(result)
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: ExportDocument(text: CSVBookCoder.encode(store.books)),
                contentType: .commaSeparatedText,
                defaultFilename: "book-collector.csv"
            ) { result in
                if case .failure(let error) = result {
                    showAlert(error.localizedDescription)
                }
            }
            .alert("提示", isPresented: $showingAlert) {
                if offerManualInput {
                    Button("手动输入") {
                        offerManualInput = false
                        showingAdd = true
                    }
                }
                Button("好", role: .cancel) {
                    offerManualInput = false
                }
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func addScannedISBN(_ isbn: String) async {
        do {
            lookupCandidates = try await WorldCatService().lookupCandidates(isbn: isbn)
            showingLookupResults = true
        } catch {
            var fallback = Book()
            fallback.identifierKind = .isbn
            fallback.isbn = isbn
            fallback.entrySource = .scan
            fallback.categoryDate = Date()
            applyCurrentCategory(to: &fallback)
            fallback.normalizeIdentifiers()
            addDraftBook = fallback
            alertMessage = "没有查询到结果，请手动输入。\n\n\(error.localizedDescription)"
            offerManualInput = true
            showingAlert = true
        }
    }

    private func addLookupCandidate(_ candidate: BookLookupCandidate) {
        var book = candidate.book
        applyCurrentCategory(to: &book)
        book.entrySource = .scan
        book.categoryDate = Date()
        book.normalizeIdentifiers()
        do {
            try store.add(book)
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func applyCurrentCategory(to book: inout Book) {
        switch selectedCategory {
        case .owned:
            book.ownershipStatus = .owned
            book.ownedReadingStatus = ownedFilter == .read ? .read : .unread
            book.wishlistReadingStatus = .wantToRead
        case .wantToRead:
            if wantToReadFilter == .purchased {
                book.ownershipStatus = .owned
                book.ownedReadingStatus = .unread
            } else {
                book.ownershipStatus = .wishlist
                book.wishlistReadingStatus = .wantToRead
            }
        case .unownedRead:
            book.ownershipStatus = .wishlist
            book.wishlistReadingStatus = .read
        }
    }

    private func importFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            var books: [Book]
            if url.pathExtension.lowercased() == "xlsx" {
                let data = try Data(contentsOf: url)
                books = try XLSXBookCoder.decode(data: data, fileName: url.lastPathComponent)
                isImporting = true
                importProgressText = "正在读取 \(books.count) 本图书..."
                try store.importBooks(books)
                importProgressText = "正在后台补全 ISBN 和封面..."
                Task {
                    await enrichImportedBooksInBackground(books)
                }
                isImporting = false
                return
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                books = try CSVBookCoder.decode(text)
            }
            try store.importBooks(books)
            Task {
                await enrichImportedBooksInBackground(books)
            }
        } catch {
            isImporting = false
            showAlert(error.localizedDescription)
        }
    }

    private func enrichImportedBooksInBackground(_ books: [Book]) async {
        let service = WorldCatService()
        var batch: [Book] = []

        for (index, book) in books.enumerated() {
            let hasDoubanPage = !(book.doubanSubjectURL ?? "").trimmed.isEmpty
            let hasISBN = !book.isbn.trimmed.isEmpty || (book.identifierKind == .isbn && !book.identifier.trimmed.isEmpty)
            let needsCover = (book.coverURL ?? "").trimmed.isEmpty && book.coverPhotoData == nil
            guard hasDoubanPage || (hasISBN && needsCover) else { continue }

            if index % 50 == 0 {
                importProgressText = "后台补全 \(index)/\(books.count)"
            }

            if let enriched = try? await service.enrichDoubanExportedBook(book) {
                batch.append(enriched)
            }

            if batch.count >= 30 {
                try? store.mergeImportedBooks(batch)
                batch.removeAll()
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        if !batch.isEmpty {
            try? store.mergeImportedBooks(batch)
        }

        importProgressText = ""
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        offerManualInput = false
        showingAlert = true
    }
}

private struct CategoryHeader: View {
    @Binding var selectedCategory: LibraryCategory
    @Binding var ownedFilter: OwnedShelfFilter
    @Binding var wantToReadFilter: WantToReadShelfFilter
    @Binding var sortOrder: TimeSortOrder
    let snapshot: LibrarySnapshot

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(LibraryCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text("\(category.title) \(snapshot.count(for: category))")
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selectedCategory == category ? Color.accentColor : Color(.secondarySystemFill))
                            .foregroundStyle(selectedCategory == category ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                if selectedCategory == .owned {
                    ForEach(OwnedShelfFilter.allCases) { filter in
                        Button {
                            ownedFilter = filter
                        } label: {
                            Text("\(filter.title) \(snapshot.ownedCount(for: filter))")
                                .font(.caption.weight(.semibold))
                                .frame(width: 78)
                                .padding(.vertical, 7)
                                .background(ownedFilter == filter ? Color.accentColor.opacity(0.9) : Color(.secondarySystemFill))
                                .foregroundStyle(ownedFilter == filter ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                    }
                } else if selectedCategory == .wantToRead {
                    ForEach(WantToReadShelfFilter.allCases) { filter in
                        Button {
                            wantToReadFilter = filter
                        } label: {
                            Text("\(filter.title) \(snapshot.wantToReadCount(for: filter))")
                                .font(.caption.weight(.semibold))
                                .frame(width: 92)
                                .padding(.vertical, 7)
                                .background(wantToReadFilter == filter ? Color.accentColor.opacity(0.9) : Color(.secondarySystemFill))
                                .foregroundStyle(wantToReadFilter == filter ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Button {
                    sortOrder.toggle()
                } label: {
                    Label(sortOrder.title, systemImage: sortOrder == .descending ? "arrow.down" : "arrow.up")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemFill))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

}

private enum LibraryCategory: String, CaseIterable, Identifiable {
    case owned
    case wantToRead
    case unownedRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owned:
            return "已购"
        case .wantToRead:
            return "想读"
        case .unownedRead:
            return "未购已读"
        }
    }

    func matches(_ book: Book, snapshot: LibrarySnapshot) -> Bool {
        switch self {
        case .owned:
            return book.ownershipStatus == .owned
        case .wantToRead:
            return (book.ownershipStatus == .owned && book.ownedReadingStatus == .unread) ||
                (book.ownershipStatus == .wishlist && book.wishlistReadingStatus == .wantToRead)
        case .unownedRead:
            return book.ownershipStatus == .wishlist &&
                book.wishlistReadingStatus == .read &&
                !snapshot.hasOwnedDuplicate(of: book)
        }
    }
}

private struct LibrarySnapshot {
    let books: [Book]
    private let ownedKeys: Set<String>
    private let categoryCounts: [LibraryCategory: Int]
    private let ownedFilterCounts: [OwnedShelfFilter: Int]
    private let wantToReadFilterCounts: [WantToReadShelfFilter: Int]

    init(books: [Book]) {
        self.books = books
        let owned = books.filter { $0.ownershipStatus == .owned }
        let keys = Set(owned.flatMap(\.matchingKeys))
        ownedKeys = keys

        var ownedRead = 0
        var ownedUnread = 0
        var wantToReadOwned = 0
        var wantToReadUnpurchased = 0
        var unownedRead = 0

        for book in books {
            switch book.ownershipStatus {
            case .owned:
                if book.ownedReadingStatus == .read {
                    ownedRead += 1
                } else {
                    ownedUnread += 1
                    wantToReadOwned += 1
                }
            case .wishlist:
                if book.wishlistReadingStatus == .wantToRead {
                    wantToReadUnpurchased += 1
                } else if book.wishlistReadingStatus == .read,
                          !book.matchingKeys.contains(where: { keys.contains($0) }) {
                    unownedRead += 1
                }
            }
        }

        categoryCounts = [
            .owned: owned.count,
            .wantToRead: wantToReadOwned + wantToReadUnpurchased,
            .unownedRead: unownedRead
        ]
        ownedFilterCounts = [
            .read: ownedRead,
            .unread: ownedUnread
        ]
        wantToReadFilterCounts = [
            .purchased: wantToReadOwned,
            .unpurchased: wantToReadUnpurchased
        ]
    }

    func count(for category: LibraryCategory) -> Int {
        categoryCounts[category, default: 0]
    }

    func ownedCount(for filter: OwnedShelfFilter) -> Int {
        ownedFilterCounts[filter, default: 0]
    }

    func wantToReadCount(for filter: WantToReadShelfFilter) -> Int {
        wantToReadFilterCounts[filter, default: 0]
    }

    func hasOwnedDuplicate(of book: Book) -> Bool {
        book.matchingKeys.contains { ownedKeys.contains($0) }
    }
}

private extension Book {
    var matchingKeys: [String] {
        var keys: [String] = []
        let identifier = primaryIdentifier.trimmed.lowercased()
        if !identifier.isEmpty {
            keys.append("\(identifierKind.rawValue):\(identifier)")
        }
        if let doubanID = doubanSubjectID?.trimmed.lowercased(), !doubanID.isEmpty {
            keys.append("douban:\(doubanID)")
        }
        let normalizedTitle = title.trimmed.lowercased()
        if !normalizedTitle.isEmpty {
            keys.append("title:\(normalizedTitle)")
        }
        return keys
    }
}

private enum OwnedShelfFilter: String, CaseIterable, Identifiable {
    case read
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read:
            return "已读"
        case .unread:
            return "未读"
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .read:
            return book.ownedReadingStatus == .read
        case .unread:
            return book.ownedReadingStatus == .unread
        }
    }
}

private enum WantToReadShelfFilter: String, CaseIterable, Identifiable {
    case purchased
    case unpurchased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .purchased:
            return "已购"
        case .unpurchased:
            return "未购买"
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .purchased:
            return book.ownershipStatus == .owned && book.ownedReadingStatus == .unread
        case .unpurchased:
            return book.ownershipStatus == .wishlist && book.wishlistReadingStatus == .wantToRead
        }
    }
}

private enum TimeSortOrder: Equatable {
    case descending
    case ascending

    var title: String {
        switch self {
        case .descending:
            return "时间降序"
        case .ascending:
            return "时间升序"
        }
    }

    mutating func toggle() {
        self = self == .descending ? .ascending : .descending
    }
}

private struct FilterStatusBar: View {
    let filter: LibraryFilter
    let onReset: () -> Void

    var body: some View {
        if filter != .all {
            HStack(spacing: 10) {
                Spacer()
                Text(filter.title)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemFill))
                    .clipShape(Capsule())

                Button("全部", action: onReset)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 72)
            .padding(.bottom, 4)
        }
    }
}

private struct LookupResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [BookLookupCandidate]
    let onSelect: (BookLookupCandidate) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { candidate in
                        Button {
                            guard candidate.canSelect else { return }
                            onSelect(candidate)
                            dismiss()
                        } label: {
                            LookupCandidateRow(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                        .disabled(!candidate.canSelect)
                    }
                }
            }
            .navigationTitle("选择图书信息")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct LookupCandidateRow: View {
    let candidate: BookLookupCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverThumb(data: candidate.book.coverPhotoData, urlString: candidate.book.coverURL)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(candidate.sourceName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(candidate.canSelect && !candidate.isFallback ? Color.white : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(candidate.canSelect && !candidate.isFallback ? Color.accentColor : Color(.secondarySystemFill))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                }

                Text(candidate.book.title.isEmpty ? "未命名图书" : candidate.book.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !candidate.book.authors.isEmpty {
                    Text(candidate.book.authors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !candidate.book.publisher.isEmpty || !candidate.book.publicationDate.isEmpty {
                    Text([candidate.book.publisher, candidate.book.publicationDate].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(candidate.book.primaryIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !candidate.note.isEmpty {
                    Text(candidate.note)
                        .font(.caption)
                        .foregroundStyle(candidate.canSelect ? Color.secondary : Color.red)
                }
            }
        }
        .opacity(candidate.canSelect ? 1 : 0.7)
        .padding(.vertical, 6)
    }
}

private enum LibraryFilter: Equatable {
    case all
    case ownedAll
    case ownedRead
    case ownedUnread
    case wishlistAll
    case wishlistRead
    case wishlistWantToRead
    case wishlistPending

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .ownedAll:
            return "已买"
        case .ownedRead:
            return "已买 · 已读"
        case .ownedUnread:
            return "已买 · 未读"
        case .wishlistAll:
            return "未买"
        case .wishlistRead:
            return "未买 · 已读"
        case .wishlistWantToRead:
            return "未买 · 想读"
        case .wishlistPending:
            return "未买 · 待定"
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .all:
            return true
        case .ownedAll:
            return book.ownershipStatus == .owned
        case .ownedRead:
            return book.ownershipStatus == .owned && book.ownedReadingStatus == .read
        case .ownedUnread:
            return book.ownershipStatus == .owned && book.ownedReadingStatus == .unread
        case .wishlistAll:
            return book.ownershipStatus == .wishlist
        case .wishlistRead:
            return book.ownershipStatus == .wishlist && book.wishlistReadingStatus == .read
        case .wishlistWantToRead:
            return book.ownershipStatus == .wishlist && book.wishlistReadingStatus == .wantToRead
        case .wishlistPending:
            return book.ownershipStatus == .wishlist && book.wishlistReadingStatus == .pending
        }
    }
}

private struct BookRow: View {
    let book: Book
    let category: LibraryCategory
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                CoverThumb(data: book.coverPhotoData, urlString: book.coverURL)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 10) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title.isEmpty ? "未命名图书" : book.title)
                            .font(.headline)
                            .lineLimit(2)
                        if !book.authors.isEmpty {
                            Text(book.authors)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !book.publisher.isEmpty {
                            Text(book.publisher)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("\(book.identifierKind.rawValue) \(book.primaryIdentifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(statusText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Text(book.categoryDateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch category {
        case .owned:
            return book.ownedReadingStatus.rawValue
        case .wantToRead:
            return book.ownershipStatus == .owned ? "已购" : "未购买"
        case .unownedRead:
            return "已读"
        }
    }

    private var statusColor: Color {
        switch category {
        case .owned:
            return book.ownedReadingStatus == .read ? .accentColor : .secondary
        case .wantToRead:
            return .accentColor
        case .unownedRead:
            return .accentColor
        }
    }
}

private struct CoverThumb: View {
    let data: Data?
    var urlString: String? = nil

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let urlString,
                      let url = URL(string: urlString) {
                RemoteCoverImage(url: url)
            } else {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 64)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RemoteCoverImage: View {
    let url: URL
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            data = await CoverImageCache.shared.data(for: url)
        }
    }
}

private final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSURL, NSData>()

    private init() {
        cache.countLimit = 250
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func data(for url: URL) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached as Data
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://book.douban.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              !data.isEmpty else {
            return nil
        }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
