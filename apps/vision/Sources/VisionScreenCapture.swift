import AudioToolbox
import CoreImage
import CoreMedia
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit
import UIKit

enum VisionScreenCaptureError: LocalizedError {
    case unavailable
    case cancelled
    case noFrame
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Shared-content capture is unavailable on this device."
        case .cancelled: "Screen capture was cancelled."
        case .noFrame: "The selected content did not produce an image."
        case .encodingFailed: "The captured frame could not be encoded."
        }
    }
}

@MainActor
@Observable
final class VisionScreenCaptureController {
    static let utilityWindowID = "screenshot-utility"

    enum Mode: Equatable {
        case view

        var selectionStyle: SCShareableContentStyle {
            .display
        }

        var readyLabel: String {
            "Ready to capture"
        }
    }

    enum Phase: Equatable {
        case idle
        case choosing(Mode)
        case preparing(Mode)
        case ready(Mode)
        case counting(Mode, Int)
        case capturing(Mode)
    }

    private(set) var phase = Phase.idle

    @ObservationIgnored
    private var session: VisionScreenCaptureSession?
    @ObservationIgnored
    private var countdownTask: Task<Void, Never>?
    @ObservationIgnored
    private var onCaptured: ((Data) -> Void)?
    @ObservationIgnored
    private var onFailure: ((Error) -> Void)?

    static var isSupported: Bool { SCContentSharingPicker.shared.isAvailable }

    var isActive: Bool { phase != .idle }

    var statusLabel: String {
        switch phase {
        case .idle: "Screen capture"
        case .choosing:
            "Choose the full display"
        case .preparing: "Starting capture…"
        case let .ready(mode): mode.readyLabel
        case let .counting(_, seconds): "Capturing in \(seconds)…"
        case .capturing: "Capturing…"
        }
    }

    func begin(
        mode: Mode,
        onCaptured: @escaping (Data) -> Void,
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        guard phase == .idle else { return }
        guard Self.isSupported else {
            onFailure(VisionScreenCaptureError.unavailable)
            return
        }

        self.onCaptured = onCaptured
        self.onFailure = onFailure
        phase = .choosing(mode)

        let session = VisionScreenCaptureSession(
            mode: mode,
            onPreparing: { [weak self] in
                self?.phase = .preparing(mode)
            },
            onReady: { [weak self] in
                guard let self else { return }
                phase = .ready(mode)
                onReady()
            },
            onCancelled: { [weak self] in
                self?.reset()
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                let callback = self.onFailure
                reset()
                callback?(error)
            }
        )
        self.session = session
        session.presentPicker()
    }

    func captureNow() {
        guard let mode = activeMode, let session else { return }
        countdownTask?.cancel()
        countdownTask = nil
        phase = .capturing(mode)

        Task {
            do {
                let data = try await session.captureLatestFrame()
                AudioServicesPlaySystemSound(1108)
                let callback = onCaptured
                reset()
                callback?(data)
            } catch is CancellationError {
                reset()
            } catch {
                let callback = onFailure
                reset()
                callback?(error)
            }
        }
    }

    func captureAfter(seconds: Int) {
        guard let mode = activeMode, session != nil else { return }
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: max(1, seconds), through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                phase = .counting(mode, remaining)
                AudioServicesPlaySystemSound(1104)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            captureNow()
        }
    }

    func cancel() {
        let session = session
        reset()
        Task { await session?.cancel() }
    }

    private var activeMode: Mode? {
        switch phase {
        case let .choosing(mode), let .preparing(mode), let .ready(mode),
             let .counting(mode, _), let .capturing(mode): mode
        case .idle: nil
        }
    }

    private func reset() {
        countdownTask?.cancel()
        countdownTask = nil
        session = nil
        onCaptured = nil
        onFailure = nil
        phase = .idle
    }
}

private final class VisionLatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var announcedFirstFrame = false

    func store(_ frame: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latestFrame = frame
        guard !announcedFirstFrame else { return false }
        announcedFirstFrame = true
        return true
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }
}

@MainActor
private final class VisionScreenCaptureSession: NSObject,
    SCContentSharingPickerObserver,
    SCStreamDelegate,
    SCStreamOutput
{
    private static weak var activeSession: VisionScreenCaptureSession?

    private let mode: VisionScreenCaptureController.Mode
    private let onPreparing: () -> Void
    private let onReady: () -> Void
    private let onCancelled: () -> Void
    private let onFailure: (Error) -> Void
    private let sampleQueue = DispatchQueue(label: "codes.t3.vision.screen-capture")
    private let frames = VisionLatestFrameStore()
    private var stream: SCStream?
    private var isStopping = false

    init(
        mode: VisionScreenCaptureController.Mode,
        onPreparing: @escaping () -> Void,
        onReady: @escaping () -> Void,
        onCancelled: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.mode = mode
        self.onPreparing = onPreparing
        self.onReady = onReady
        self.onCancelled = onCancelled
        self.onFailure = onFailure
    }

    func presentPicker() {
        guard Self.activeSession == nil, SCContentSharingPicker.shared.isAvailable else {
            onFailure(VisionScreenCaptureError.unavailable)
            return
        }
        Self.activeSession = self
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present(using: mode.selectionStyle)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in await startStream(filter: filter) }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            await stopStream()
            onCancelled()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            await stopStream()
            onFailure(error)
        }
    }

    private func startStream(filter: SCContentFilter) async {
        do {
            onPreparing()
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            await stopStream()
            onFailure(error)
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if frames.store(pixelBuffer) {
            Task { @MainActor in onReady() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard !isStopping else { return }
            await stopStream()
            onFailure(error)
        }
    }

    func captureLatestFrame() async throws -> Data {
        guard let pixelBuffer = frames.current() else {
            await stopStream()
            throw VisionScreenCaptureError.noFrame
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.94) else {
            await stopStream()
            throw VisionScreenCaptureError.encodingFailed
        }
        await stopStream()
        return data
    }

    func cancel() async {
        await stopStream()
    }

    private func stopStream() async {
        guard !isStopping else { return }
        isStopping = true
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let stream = stream
        self.stream = nil
        try? await stream?.stopCapture()
        if Self.activeSession === self {
            Self.activeSession = nil
        }
    }
}
