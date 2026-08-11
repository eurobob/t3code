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

private enum VisionAnnotationTool: String, CaseIterable {
    case pen
    case marker
    case eraser

    var title: String {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .eraser: "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser.fill"
        }
    }
}

private enum VisionAnnotationColor: String, CaseIterable {
    case red
    case yellow
    case green
    case blue
    case white

    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .white: .white
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .white: .white
        }
    }
}

private enum VisionAnnotationWidth: String, CaseIterable {
    case thin
    case medium
    case thick

    var title: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .thin: 5
        case .medium: 12
        case .thick: 24
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
    @State private var selectedTool = VisionAnnotationTool.pen
    @State private var selectedColor = VisionAnnotationColor.red
    @State private var selectedWidth = VisionAnnotationWidth.medium

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

            if let editor {
                annotationToolbar(editor: editor)
            }

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
                let prepared = try VisionPaperAnnotationEditor(attachment: session.attachment)
                editor = prepared
                applySelectedTool(to: prepared)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func annotationToolbar(editor: VisionPaperAnnotationEditor) -> some View {
        HStack(spacing: 16) {
            Picker("Tool", selection: $selectedTool) {
                ForEach(VisionAnnotationTool.allCases, id: \.self) { tool in
                    Label(tool.title, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            HStack(spacing: 8) {
                ForEach(VisionAnnotationColor.allCases, id: \.self) { color in
                    Button {
                        selectedColor = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(
                                    selectedColor == color ? Color.primary : Color.clear,
                                    lineWidth: 3
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(color.rawValue.capitalized) ink")
                }
            }
            .opacity(selectedTool == .eraser ? 0.35 : 1)

            Picker("Width", selection: $selectedWidth) {
                ForEach(VisionAnnotationWidth.allCases, id: \.self) { width in
                    Text(width.title).tag(width)
                }
            }
            .frame(width: 150)
            .disabled(selectedTool == .eraser)

            Spacer()

            Button {
                editor.showSystemTools()
            } label: {
                Label("More Tools", systemImage: "paintpalette")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .onChange(of: selectedTool) { applySelectedTool(to: editor) }
        .onChange(of: selectedColor) { applySelectedTool(to: editor) }
        .onChange(of: selectedWidth) { applySelectedTool(to: editor) }
    }

    private func applySelectedTool(to editor: VisionPaperAnnotationEditor) {
        editor.select(
            selectedTool,
            color: selectedColor.uiColor,
            width: selectedWidth.points
        )
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
        toolPicker.addObserver(viewController)
        viewController.pencilKitResponderState.activeToolPicker = toolPicker
        viewController.pencilKitResponderState.toolPickerVisibility = .visible
        activateDrawingAndFitImage()
    }

    func select(_ tool: VisionAnnotationTool, color: UIColor, width: CGFloat) {
        switch tool {
        case .pen:
            viewController.drawingTool = PKInkingTool(.pen, color: color, width: width)
        case .marker:
            viewController.drawingTool = PKInkingTool(
                .marker,
                color: color,
                width: max(12, width * 1.8)
            )
        case .eraser:
            viewController.drawingTool = PKEraserTool(.vector)
        }
        activateDrawing()
    }

    func showSystemTools() {
        activateDrawing()
        viewController.pencilKitResponderState.toolPickerVisibility = .visible
    }

    func activateDrawingAndFitImage() {
        activateDrawing()
        guard let bounds = viewController.markup?.bounds else { return }
        viewController.setContentVisibleFrame(bounds, animated: false)
    }

    private func activateDrawing() {
        viewController.directTouchMode = .drawing
        viewController.directTouchAutomaticallyDraws = true
        viewController.indirectPointerTouchMode = .drawing
        viewController.pencilKitResponderState.activeToolPicker = toolPicker
        _ = viewController.becomeFirstResponder()
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

    func makeUIViewController(context: Context) -> VisionPaperMarkupHostController {
        VisionPaperMarkupHostController(editor: editor)
    }

    func updateUIViewController(
        _ viewController: VisionPaperMarkupHostController,
        context: Context
    ) {}
}

@MainActor
private final class VisionPaperMarkupHostController: UIViewController {
    private let editor: VisionPaperAnnotationEditor
    private var fittedSize = CGSize.zero

    init(editor: VisionPaperAnnotationEditor) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let canvas = editor.viewController
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas.view)
        NSLayoutConstraint.activate([
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        canvas.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.activateDrawingAndFitImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != fittedSize else { return }
        fittedSize = size
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.editor.activateDrawingAndFitImage()
        }
    }
}
