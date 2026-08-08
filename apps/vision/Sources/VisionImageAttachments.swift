import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct VisionDraftAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let data: Data
    let thumbnailData: Data
    let filename: String
    let mimeType: String

    init(
        id: UUID = UUID(),
        data: Data,
        thumbnailData: Data,
        filename: String,
        mimeType: String
    ) {
        self.id = id
        self.data = data
        self.thumbnailData = thumbnailData
        self.filename = filename
        self.mimeType = mimeType
    }

    func uploadValue() throws -> UploadChatImageAttachment {
        try UploadChatImageAttachment(data: data, name: filename, mimeType: mimeType)
    }
}

struct VisionImageAttachmentPicker: View {
    @Binding var attachments: [VisionDraftAttachment]
    let isEnabled: Bool

    @State private var showsSources = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var isPreparing = false
    @State private var errorMessage: String?

    init(
        attachments: Binding<[VisionDraftAttachment]>,
        isEnabled: Bool = true
    ) {
        _attachments = attachments
        self.isEnabled = isEnabled
    }

    var body: some View {
        Button {
            showsSources = true
        } label: {
            Image(systemName: isPreparing ? "hourglass" : "paperclip")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.35)
        .accessibilityLabel(isPreparing ? "Preparing image" : "Add image")
        .confirmationDialog("Add image", isPresented: $showsSources) {
            Button("Photo Library") {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    showsPhotos = true
                }
            }
            Button("Files") {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    showsFiles = true
                }
            }
            Button(
                VisionScreenCapture.isSupported
                    ? "Capture Shared Content"
                    : "Capture Shared Content (Unavailable)"
            ) {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    captureSharedContent()
                }
            }
            .disabled(!VisionScreenCapture.isSupported)
            Button("Cancel", role: .cancel) {}
        } message: {
            if VisionScreenCapture.isSupported {
                Text("Capture Shared Content lets you choose a window or other shareable content and attaches one frame.")
            } else {
                Text("Screen recording is unavailable or not allowed on this device.")
            }
        }
        .sheet(isPresented: $showsPhotos) {
            VisionPhotoLibraryPicker(
                maximumCount: max(1, remainingCount),
                onSelect: { items in
                    showsPhotos = false
                    loadPhotoSelections(items)
                },
                onCancel: { showsPhotos = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showsFiles,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: loadFiles
        )
        .alert(
            "Couldn’t add image",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var remainingCount: Int { max(0, 8 - attachments.count) }
    private var canAdd: Bool { isEnabled && !isPreparing && remainingCount > 0 }

    private func loadPhotoSelections(_ items: [VisionPhotoLibraryItem]) {
        let selected = Array(items.prefix(remainingCount))
        guard !selected.isEmpty else { return }
        let firstOrdinal = attachments.count + 1
        isPreparing = true
        Task {
            defer { isPreparing = false }
            for (offset, item) in selected.enumerated() {
                do {
                    let data = try await item.loadData()
                    try await append(data, ordinal: firstOrdinal + offset)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            errorMessage = error.localizedDescription
        case let .success(urls):
            let selected = Array(urls.prefix(remainingCount))
            guard !selected.isEmpty else { return }
            let firstOrdinal = attachments.count + 1
            isPreparing = true
            Task {
                defer { isPreparing = false }
                for (offset, url) in selected.enumerated() {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        try await append(data, ordinal: firstOrdinal + offset)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func captureSharedContent() {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let data = try await VisionScreenCapture.captureImageData()
                try await append(data, ordinal: attachments.count + 1)
            } catch VisionScreenCaptureError.cancelled {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func append(_ data: Data, ordinal: Int) async throws {
        let attachment = try await Task.detached(priority: .userInitiated) {
            try VisionImageProcessor.attachment(from: data, ordinal: ordinal)
        }.value
        guard attachments.count < 8 else { return }
        attachments.append(attachment)
    }
}

struct VisionAttachmentStrip: View {
    @Binding var attachments: [VisionDraftAttachment]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: UIImage(data: attachment.thumbnailData) ?? UIImage())
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.black.opacity(0.75), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 8, y: -8)
                            .accessibilityLabel("Remove \(attachment.filename)")
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("\(attachments.count) image attachments")
        }
    }
}

struct VisionMessageAttachmentsView: View {
    @SwiftUI.Environment(AppModel.self) private var appModel
    let attachments: [ChatAttachment]

    @State private var urls: [String: URL] = [:]
    @State private var previewURL: URL?

    var body: some View {
        if !attachments.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(attachments) { attachment in
                    Button {
                        previewURL = urls[attachment.id]
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                if let url = urls[attachment.id] {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                } else {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 140)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Text(attachment.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(urls[attachment.id] == nil)
                    .task(id: attachment.id) {
                        guard attachment.mimeType.hasPrefix("image/") else { return }
                        urls[attachment.id] = try? await appModel.attachmentURL(id: attachment.id)
                    }
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { previewURL != nil },
                    set: { if !$0 { previewURL = nil } }
                )
            ) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    if let previewURL {
                        AsyncImage(url: previewURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                        .padding(40)
                    }
                    Button("Done") { previewURL = nil }
                        .buttonStyle(.borderedProminent)
                        .padding(28)
                }
            }
        }
    }
}

struct VisionPhotoLibraryItem: @unchecked Sendable {
    let provider: NSItemProvider

    func loadData() async throws -> Data {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            throw VisionImageAttachmentError.invalidImage
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? VisionImageAttachmentError.encodingFailed)
                }
            }
        }
    }
}

private struct VisionPhotoLibraryPicker: UIViewControllerRepresentable {
    let maximumCount: Int
    let onSelect: ([VisionPhotoLibraryItem]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = maximumCount
        configuration.preferredAssetRepresentationMode = .compatible
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: ([VisionPhotoLibraryItem]) -> Void
        let onCancel: () -> Void

        init(
            onSelect: @escaping ([VisionPhotoLibraryItem]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onCancel()
                return
            }
            onSelect(results.map { VisionPhotoLibraryItem(provider: $0.itemProvider) })
        }
    }
}

enum VisionImageProcessor {
    private static let maximumDimension: CGFloat = 2_048

    static func attachment(from sourceData: Data, ordinal: Int) throws -> VisionDraftAttachment {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw VisionImageAttachmentError.invalidImage
        }

        let prepared = UIImage(cgImage: image)
        guard let data = prepared.jpegData(compressionQuality: 0.82),
              let thumbnail = thumbnail(from: prepared) else {
            throw VisionImageAttachmentError.encodingFailed
        }
        guard data.count <= UploadChatImageAttachment.maximumBytes else {
            throw VisionImageAttachmentError.tooLarge
        }
        return VisionDraftAttachment(
            data: data,
            thumbnailData: thumbnail,
            filename: "Image \(ordinal).jpg",
            mimeType: "image/jpeg"
        )
    }

    private static func thumbnail(from image: UIImage) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 160 / longestSide)
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.72)
    }
}

enum VisionImageAttachmentError: LocalizedError {
    case invalidImage
    case encodingFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage: "That image could not be read."
        case .encodingFailed: "That image could not be prepared."
        case .tooLarge: "Images must be smaller than 10 MB."
        }
    }
}
