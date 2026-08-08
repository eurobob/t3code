import Foundation
import CoreImage
import CoreMedia
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

enum VisionScreenCapture {
    static var isSupported: Bool {
        SCContentSharingPicker.shared.isAvailable
    }

    static func captureImageData() async throws -> Data {
        try await VisionScreenCaptureSession.capture()
    }
}

@MainActor
private final class VisionScreenCaptureSession: NSObject,
    SCContentSharingPickerObserver,
    SCStreamDelegate,
    SCStreamOutput
{
    private static var activeSession: VisionScreenCaptureSession?

    private let sampleQueue = DispatchQueue(label: "codes.t3.vision.screen-capture")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var continuation: CheckedContinuation<Data, Error>?
    private var isFinished = false

    static func capture() async throws -> Data {
        guard activeSession == nil, SCContentSharingPicker.shared.isAvailable else {
            throw VisionScreenCaptureError.unavailable
        }
        let session = VisionScreenCaptureSession()
        activeSession = session
        return try await withCheckedThrowingContinuation { continuation in
            session.continuation = continuation
            let picker = SCContentSharingPicker.shared
            picker.add(session)
            picker.isActive = true
            picker.present()
        }
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
        Task { @MainActor in finish(.failure(VisionScreenCaptureError.cancelled)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }

    private func startStream(filter: SCContentFilter) async {
        do {
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            finish(.failure(error))
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
        Task { @MainActor in
            guard !isFinished else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = imageContext.createCGImage(image, from: image.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.94) else {
                finish(.failure(VisionScreenCaptureError.encodingFailed))
                return
            }
            finish(.success(data))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let stream = stream
        self.stream = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        Self.activeSession = nil
        Task {
            try? await stream?.stopCapture()
            continuation?.resume(with: result)
        }
    }
}
