import Observation
import PaperKit
import PencilKit
import SwiftUI
import UIKit

enum VisionImageAnnotationError: LocalizedError {
    case invalidImage
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "That image could not be opened for annotation."
        case .renderingFailed: "The annotated image could not be rendered."
        }
    }
}

@MainActor
@Observable
final class VisionImageAnnotationController {
    static let windowID = "image-annotation"

    struct Session: Identifiable {
        let id = UUID()
        let attachment: VisionDraftAttachment
    }

    private(set) var session: Session?

    @ObservationIgnored
    private var onSave: ((VisionDraftAttachment) -> Void)?

    func begin(
        attachment: VisionDraftAttachment,
        onSave: @escaping (VisionDraftAttachment) -> Void
    ) {
        session = Session(attachment: attachment)
        self.onSave = onSave
    }

    func save(_ attachment: VisionDraftAttachment) {
        let callback = onSave
        session = nil
        onSave = nil
        callback?(attachment)
    }

    func cancel() {
        session = nil
        onSave = nil
    }
}

struct VisionImageAnnotationView: View {
    @SwiftUI.Environment(VisionImageAnnotationController.self) private var controller
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session = controller.session {
                VisionPaperAnnotationView(session: session)
                    .id(session.id)
            } else {
                ProgressView()
                    .onAppear { dismiss() }
            }
        }
        .onChange(of: controller.session?.id) {
            if controller.session == nil {
                dismiss()
            }
        }
    }
}

private struct VisionPaperAnnotationView: View {
    @SwiftUI.Environment(VisionImageAnnotationController.self) private var controller
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let session: VisionImageAnnotationController.Session

    @State private var editor: VisionPaperAnnotationEditor?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    controller.cancel()
                    dismiss()
                }

                Spacer()

                if let editor {
                    Button {
                        editor.undo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        editor.redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                }

                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor == nil || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Group {
                if let editor {
                    VisionPaperMarkupCanvas(editor: editor)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn’t annotate image",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Preparing annotation tools…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.id) {
            do {
                editor = try VisionPaperAnnotationEditor(attachment: session.attachment)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let editor, !isSaving else { return }
        isSaving = true
        Task {
            do {
                let attachment = try await editor.renderedAttachment()
                controller.save(attachment)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

@MainActor
private final class VisionPaperAnnotationEditor {
    let attachment: VisionDraftAttachment
    let viewController: PaperMarkupViewController

    private let toolPicker = PKToolPicker()

    init(attachment: VisionDraftAttachment) throws {
        guard let image = UIImage(data: attachment.data),
              let cgImage = image.cgImage else {
            throw VisionImageAnnotationError.invalidImage
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: cgImage.width,
            height: cgImage.height
        )
        var markup = PaperMarkup(bounds: bounds)
        let background = ImageMarkup(
            image: cgImage,
            frame: bounds,
            allowedInteractions: .readOnly
        )
        markup.subelements.append(contentsOf: [background])

        let viewController = PaperMarkupViewController(
            markup: markup,
            supportedFeatureSet: .latest
        )
        self.attachment = attachment
        self.viewController = viewController

        viewController.isEditable = true
        viewController.directTouchMode = .drawing
        viewController.directTouchAutomaticallyDraws = true
        viewController.indirectPointerTouchMode = .drawing
        toolPicker.addObserver(viewController)
        viewController.pencilKitResponderState.activeToolPicker = toolPicker
        viewController.pencilKitResponderState.toolPickerVisibility = .visible
    }

    func undo() {
        viewController.undoManager?.undo()
    }

    func redo() {
        viewController.undoManager?.redo()
    }

    func renderedAttachment() async throws -> VisionDraftAttachment {
        guard let markup = viewController.markup else {
            throw VisionImageAnnotationError.renderingFailed
        }
        let width = max(1, Int(markup.bounds.width.rounded()))
        let height = max(1, Int(markup.bounds.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisionImageAnnotationError.renderingFailed
        }

        await markup.draw(
            in: context,
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let rendered = context.makeImage(),
              let data = UIImage(cgImage: rendered).jpegData(compressionQuality: 0.9) else {
            throw VisionImageAnnotationError.renderingFailed
        }
        return try VisionImageProcessor.replacement(from: data, for: attachment)
    }
}

private struct VisionPaperMarkupCanvas: UIViewControllerRepresentable {
    let editor: VisionPaperAnnotationEditor

    func makeUIViewController(context: Context) -> PaperMarkupViewController {
        editor.viewController
    }

    func updateUIViewController(
        _ viewController: PaperMarkupViewController,
        context: Context
    ) {}
}
