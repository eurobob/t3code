import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit

enum VisionFrameReviewError: LocalizedError {
    case noVideoTrack
    case frameExtractionFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The captured clip does not contain video frames."
        case .frameExtractionFailed: "That frame could not be extracted from the clip."
        }
    }
}

@MainActor
@Observable
final class VisionFrameReviewController {
    static let windowID = "frame-review"

    struct Session: Identifiable {
        let id = UUID()
        let url: URL
        let maximumSelectionCount: Int
    }

    private(set) var session: Session?

    @ObservationIgnored
    private var onAdd: (([VisionDraftAttachment]) -> Void)?

    func begin(
        url: URL,
        maximumSelectionCount: Int,
        onAdd: @escaping ([VisionDraftAttachment]) -> Void
    ) {
        discardCurrentClip()
        session = Session(
            url: url,
            maximumSelectionCount: maximumSelectionCount
        )
        self.onAdd = onAdd
    }

    func add(_ attachments: [VisionDraftAttachment]) {
        let callback = onAdd
        finish()
        callback?(attachments)
    }

    func cancel() {
        finish()
    }

    private func finish() {
        discardCurrentClip()
        session = nil
        onAdd = nil
    }

    private func discardCurrentClip() {
        if let url = session?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct VisionFrameReviewView: View {
    @SwiftUI.Environment(VisionFrameReviewController.self) private var controller
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session = controller.session {
                VisionFrameReviewEditorView(session: session)
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

private struct VisionFrameReviewEditorView: View {
    @SwiftUI.Environment(VisionFrameReviewController.self) private var controller
    @SwiftUI.Environment(VisionImageAnnotationController.self) private var imageAnnotation
    @SwiftUI.Environment(\.openWindow) private var openWindow
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let session: VisionFrameReviewController.Session

    @State private var model: VisionFrameReviewModel
    @State private var errorMessage: String?

    init(session: VisionFrameReviewController.Session) {
        self.session = session
        _model = State(initialValue: VisionFrameReviewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    controller.cancel()
                    dismiss()
                }
                Spacer()
                Text("\(model.selectedFrames.count) of \(session.maximumSelectionCount) frames selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Add Selected") {
                    controller.add(model.selectedFrames.map(\.attachment))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedFrames.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            VideoPlayer(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            VStack(spacing: 12) {
                VisionVelocityScrubber(model: model)

                HStack(spacing: 12) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    }

                    Button {
                        model.move(byFrames: -1)
                    } label: {
                        Label("Previous Frame", systemImage: "backward.frame.fill")
                    }

                    Button {
                        model.move(byFrames: 1)
                    } label: {
                        Label("Next Frame", systemImage: "forward.frame.fill")
                    }

                    Spacer()

                    Button {
                        extractCurrentFrame(annotate: true)
                    } label: {
                        Label("Annotate Frame", systemImage: "pencil.tip.crop.circle")
                    }
                    .disabled(!model.isReady || model.isExtracting || model.selectionIsFull)

                    Button {
                        extractCurrentFrame(annotate: false)
                    } label: {
                        Label("Select Frame", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isReady || model.isExtracting || model.selectionIsFull)
                }

                selectedFrameStrip
            }
            .padding(20)
            .background(.thinMaterial)
        }
        .task(id: session.id) {
            do {
                try await model.prepare()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Couldn’t capture frame",
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

    private var selectedFrameStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(model.selectedFrames) { frame in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            model.seek(to: frame.time)
                        } label: {
                            VStack(spacing: 4) {
                                Image(uiImage: UIImage(data: frame.attachment.thumbnailData) ?? UIImage())
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 104, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(model.timeLabel(frame.time))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.remove(frame.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                                .frame(width: 22, height: 22)
                                .background(.black.opacity(0.75), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: -7)

                        Button {
                            annotate(frame)
                        } label: {
                            Image(systemName: "pencil.tip")
                                .font(.caption2.bold())
                                .frame(width: 22, height: 22)
                                .background(.blue.opacity(0.9), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: 36)
                    }
                    .padding(.top, 7)
                    .padding(.trailing, 7)
                }
            }
        }
        .frame(height: model.selectedFrames.isEmpty ? 0 : 90)
        .scrollIndicators(.hidden)
    }

    private func extractCurrentFrame(annotate: Bool) {
        Task {
            do {
                let frame = try await model.extractCurrentFrame()
                if annotate {
                    self.annotate(frame)
                } else {
                    model.append(frame)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func annotate(_ frame: VisionSelectedFrame) {
        imageAnnotation.begin(attachment: frame.attachment) { replacement in
            model.replaceOrAppend(frame: frame, attachment: replacement)
        }
        openWindow(id: VisionImageAnnotationController.windowID)
    }
}

private struct VisionVelocityScrubber: View {
    let model: VisionFrameReviewModel

    @State private var lastTranslation: CGFloat?
    @State private var lastTime: Date?
    @State private var frameRemainder = 0.0
    @State private var scrubRate = 1

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(model.timeLabel(model.currentTime))
                Spacer()
                Text("Frame \(model.currentFrameIndex + 1) / \(max(1, model.frameCount))")
                Spacer()
                Text("\(scrubRate)× scrub")
                    .foregroundStyle(scrubRate == 1 ? .secondary : .primary)
                    .frame(width: 82, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.22))
                        .frame(height: 12)
                    Capsule()
                        .fill(.blue.opacity(0.65))
                        .frame(width: max(12, proxy.size.width * model.progress), height: 12)
                    Circle()
                        .fill(.white)
                        .shadow(radius: 3)
                        .frame(width: 28, height: 28)
                        .offset(x: max(0, (proxy.size.width - 28) * model.progress))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: proxy.size.width))
            }
            .frame(height: 34)

            Text("Drag slowly for individual frames; move faster to scan at 2×, 5×, or 10×. Tap to jump.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Velocity-sensitive video timeline")
        .accessibilityValue(model.timeLabel(model.currentTime))
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.pause()
                guard let previousTranslation = lastTranslation,
                      let previousTime = lastTime else {
                    lastTranslation = value.translation.width
                    lastTime = value.time
                    return
                }

                let distance = value.translation.width - previousTranslation
                let elapsed = max(1.0 / 120.0, value.time.timeIntervalSince(previousTime))
                let velocity = abs(Double(distance) / elapsed)
                let rate = rate(for: velocity)
                scrubRate = rate
                frameRemainder += Double(distance) * Double(rate) / 14
                let frames = Int(frameRemainder.rounded(.towardZero))
                if frames != 0 {
                    model.move(byFrames: frames)
                    frameRemainder -= Double(frames)
                }
                lastTranslation = value.translation.width
                lastTime = value.time
            }
            .onEnded { value in
                if abs(value.translation.width) < 4 {
                    model.seek(toProgress: min(1, max(0, value.location.x / max(1, width))))
                }
                lastTranslation = nil
                lastTime = nil
                frameRemainder = 0
                scrubRate = 1
            }
    }

    private func rate(for velocity: Double) -> Int {
        switch velocity {
        case ..<90: 1
        case ..<260: 2
        case ..<650: 5
        default: 10
        }
    }
}

private struct VisionSelectedFrame: Identifiable {
    let id: UUID
    let time: TimeInterval
    let attachment: VisionDraftAttachment
}

@MainActor
@Observable
private final class VisionFrameReviewModel {
    let session: VisionFrameReviewController.Session
    @ObservationIgnored let player: AVPlayer

    private(set) var duration = 0.0
    private(set) var frameRate = 30.0
    private(set) var currentTime = 0.0
    private(set) var selectedFrames: [VisionSelectedFrame] = []
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var isExtracting = false

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private var timeObserver: Any?

    init(session: VisionFrameReviewController.Session) {
        self.session = session
        asset = AVURLAsset(url: session.url)
        player = AVPlayer(url: session.url)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var frameCount: Int { max(1, Int((duration * frameRate).rounded(.down))) }
    var currentFrameIndex: Int {
        min(frameCount - 1, max(0, Int((currentTime * frameRate).rounded())))
    }
    var progress: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }
    var selectionIsFull: Bool { selectedFrames.count >= session.maximumSelectionCount }

    func prepare() async throws {
        let loadedDuration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VisionFrameReviewError.noVideoTrack }
        let loadedFrameRate = try await track.load(.nominalFrameRate)
        duration = max(0, loadedDuration.seconds)
        frameRate = loadedFrameRate > 0 ? Double(loadedFrameRate) : 30
        isReady = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = min(self.duration, max(0, time.seconds))
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func togglePlayback() {
        if player.rate == 0 {
            if currentTime >= duration - (1 / frameRate) { seek(to: 0) }
            player.play()
            isPlaying = true
        } else {
            pause()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func move(byFrames frames: Int) {
        seek(to: Double(currentFrameIndex + frames) / frameRate)
    }

    func seek(toProgress progress: Double) {
        seek(to: duration * progress)
    }

    func seek(to seconds: TimeInterval) {
        pause()
        let frame = min(frameCount - 1, max(0, Int((seconds * frameRate).rounded())))
        let resolved = Double(frame) / frameRate
        currentTime = resolved
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: resolved, preferredTimescale: 60_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func timeLabel(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d.%03d", Int(seconds) / 60, Int(seconds) % 60, Int((seconds * 1_000).rounded()) % 1_000)
    }

    func extractCurrentFrame() async throws -> VisionSelectedFrame {
        guard !selectionIsFull else { throw VisionFrameReviewError.frameExtractionFailed }
        isExtracting = true
        defer { isExtracting = false }
        let frameIndex = currentFrameIndex
        let time = Double(frameIndex) / frameRate
        let data = try await Self.extractJPEG(
            from: asset,
            at: CMTime(seconds: time, preferredTimescale: 60_000)
        )
        let prepared = try await Task.detached(priority: .userInitiated) {
            try VisionImageProcessor.attachment(from: data, ordinal: frameIndex + 1)
        }.value
        let attachment = VisionDraftAttachment(
            data: prepared.data,
            thumbnailData: prepared.thumbnailData,
            filename: "Frame \(frameIndex + 1).jpg",
            mimeType: prepared.mimeType
        )
        return VisionSelectedFrame(id: attachment.id, time: time, attachment: attachment)
    }

    func append(_ frame: VisionSelectedFrame) {
        guard !selectionIsFull else { return }
        selectedFrames.append(frame)
    }

    func replaceOrAppend(frame: VisionSelectedFrame, attachment: VisionDraftAttachment) {
        if let index = selectedFrames.firstIndex(where: { $0.id == frame.id }) {
            selectedFrames[index] = VisionSelectedFrame(
                id: frame.id,
                time: frame.time,
                attachment: attachment
            )
        } else if !selectionIsFull {
            selectedFrames.append(VisionSelectedFrame(
                id: frame.id,
                time: frame.time,
                attachment: attachment
            ))
        }
    }

    func remove(_ id: UUID) {
        selectedFrames.removeAll { $0.id == id }
    }

    private static func extractJPEG(from asset: AVAsset, at time: CMTime) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                if result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? VisionFrameReviewError.frameExtractionFailed)
                }
            }
        }
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.94) else {
            throw VisionFrameReviewError.frameExtractionFailed
        }
        return data
    }
}
