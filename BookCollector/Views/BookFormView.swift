import PhotosUI
import SwiftUI
import UIKit

enum BookFormMode: Identifiable {
    case add(Book)
    case edit(Book)

    var id: UUID {
        switch self {
        case .add(let book), .edit(let book):
            return book.id
        }
    }

    var title: String {
        switch self {
        case .add:
            return "录入图书"
        case .edit:
            return "编辑图书"
        }
    }

    var book: Book {
        switch self {
        case .add(let book), .edit(let book):
            return book
        }
    }
}

struct BookFormView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @State private var book: Book
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var alertMessage = ""
    @State private var showingAlert = false

    let mode: BookFormMode

    init(mode: BookFormMode) {
        self.mode = mode
        _book = State(initialValue: mode.book)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书号") {
                    Picker("书号类型", selection: $book.identifierKind) {
                        ForEach(IdentifierKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }

                    TextField(identifierPlaceholder, text: identifierBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("基本信息") {
                    TextField("书名", text: $book.title)
                    TextField("原名", text: $book.originalTitle)
                    TextField("丛书名", text: $book.seriesTitle)
                    TextField("作者", text: $book.authors)
                    TextField("作者国籍", text: $book.authorNationality)
                    TextField("出版时间", text: $book.publicationDate)
                    TextField("出版社", text: $book.publisher)
                }

                Section("收藏状态") {
                    Picker("状态", selection: $book.ownershipStatus) {
                        ForEach(OwnershipStatus.allCases) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)

                    if book.ownershipStatus == .owned {
                        Picker("阅读标签", selection: $book.ownedReadingStatus) {
                            ForEach(OwnedReadingStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                    } else {
                        Picker("阅读标签", selection: $book.wishlistReadingStatus) {
                            ForEach(WishlistReadingStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                    }

                    Picker("录入方式", selection: $book.entrySource) {
                        ForEach(EntrySource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                }

                Section("封面照片") {
                    if let data = book.coverPhotoData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("选择照片", systemImage: "photo")
                    }

                    Button {
                        showingCamera = true
                    } label: {
                        Label("拍摄照片", systemImage: "camera")
                    }

                    if book.ownershipStatus == .owned, book.entrySource == .manual {
                        Text("手写录入已买图书时必须添加照片。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        book.coverPhotoData = data
                    }
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraPicker { image in
                    book.coverPhotoData = image.jpegData(compressionQuality: 0.82)
                }
            }
            .alert("无法保存", isPresented: $showingAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private var identifierPlaceholder: String {
        switch book.identifierKind {
        case .isbn:
            return "ISBN"
        case .unifiedNumber:
            return "统一书号"
        case .custom:
            return "自定义书号（不可重复）"
        }
    }

    private var identifierBinding: Binding<String> {
        Binding {
            switch book.identifierKind {
            case .isbn:
                return book.isbn
            case .unifiedNumber:
                return book.unifiedNumber
            case .custom:
                return book.customNumber
            }
        } set: { value in
            switch book.identifierKind {
            case .isbn:
                book.isbn = value
            case .unifiedNumber:
                book.unifiedNumber = value
            case .custom:
                book.customNumber = value
            }
        }
    }

    private func save() {
        do {
            switch mode {
            case .add:
                try store.add(book)
            case .edit:
                try store.update(book)
            }
            dismiss()
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
