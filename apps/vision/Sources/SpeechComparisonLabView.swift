import AVFoundation
import Foundation
import Observation
import SwiftUI
import WhisperKit

private enum SpeechLabError: LocalizedError {
    case invalidAudioFormat
    case invalidServerURL
    case microphonePermissionDenied
    case noAudioCaptured
    case serverError(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "The microphone did not provide a usable audio format."
        case .invalidServerURL:
            "Enter a complete HTTP or HTTPS whisper-server /inference URL."
        case .microphonePermissionDenied:
            "T3 Vision needs microphone access to record a comparison sample."
        case .noAudioCaptured:
            "No audio was captured. Try recording again."
        case let .serverError(status, message):
            "The transcription server returned HTTP \(status): \(message)"
        }
    }
}

private struct SpeechLabRecording: Sendable {
    let fileURL: URL
    let duration: TimeInterval
}

private final class SpeechLabSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)
        ))
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Captures one bounded sample and writes a plain 16 kHz mono PCM WAV that both
/// engines consume. Keeping the recording path independent of SpeechAnalyzer
/// makes the comparison about transcription rather than microphone input.
private final class SpeechLabRecorder {
    static let sampleRate = 16_000.0

    private let audioEngine = AVAudioEngine()
    private let sampleStore = SpeechLabSampleStore()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRecording = false

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(
                from: inputFormat,
                to: targetFormat
              ) else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw SpeechLabError.invalidAudioFormat
        }

        self.targetFormat = targetFormat
        self.converter = converter
        sampleStore.reset()

        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            self.targetFormat = nil
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
    }

    func stop() throws -> SpeechLabRecording {
        stopCapture()
        let samples = sampleStore.snapshot()
        guard !samples.isEmpty else { throw SpeechLabError.noAudioCaptured }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-speech-lab-\(UUID().uuidString).wav")
        try SpeechLabWaveFile.write(samples: samples, to: fileURL)
        return SpeechLabRecording(
            fileURL: fileURL,
            duration: Double(samples.count) / Self.sampleRate
        )
    }

    func cancel() {
        stopCapture()
        sampleStore.reset()
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        if buffer.format == targetFormat {
            sampleStore.append(buffer)
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        )
        guard capacity > 0,
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
              ) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return }
        sampleStore.append(output)
    }

    private func stopCapture() {
        guard isRecording else { return }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        converter = nil
        targetFormat = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

private enum SpeechLabWaveFile {
    static func write(samples: [Float], to url: URL) throws {
        let bytesPerSample = 2
        let payloadSize = samples.count * bytesPerSample
        var data = Data()
        data.reserveCapacity(44 + payloadSize)

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + payloadSize), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(SpeechLabRecorder.sampleRate), to: &data)
        append(UInt32(SpeechLabRecorder.sampleRate * Double(bytesPerSample)), to: &data)
        append(UInt16(bytesPerSample), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(payloadSize), to: &data)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)), to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append<Value: FixedWidthInteger>(
        _ value: Value,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }
}

private enum SpeechLabServer {
    private struct Response: Decodable {
        let text: String
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    static func validatedEndpoint(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func transcribe(recording: SpeechLabRecording, endpoint: URL) async throws -> String {
        let audio = try Data(contentsOf: recording.fileURL)
        let boundary = "T3SpeechLab-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(audio: audio, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechLabError.serverError(
                status: 0,
                message: "The server did not return an HTTP response."
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw SpeechLabError.serverError(
                status: httpResponse.statusCode,
                message: message
            )
        }
        return try JSONDecoder().decode(Response.self, from: data).text
    }

    private static func multipartBody(audio: Data, boundary: String) -> Data {
        var body = Data()
        func append(_ value: String) {
            body.append(contentsOf: value.utf8)
        }
        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField(name: "language", value: "auto")
        appendField(name: "temperature", value: "0.0")
        appendField(name: "temperature_inc", value: "0.2")
        appendField(name: "no_timestamps", value: "true")
        appendField(name: "response_format", value: "json")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

@MainActor
@Observable
private final class SpeechComparisonLabModel {
    static let whisperKitModel = "large-v3-v20240930_626MB"
    static let maximumRecordingDuration: TimeInterval = 60

    enum PreparationState: Equatable {
        case notStarted
        case preparing
        case ready
        case failed(String)
    }

    enum CapturePhase: Equatable {
        case idle
        case recording
        case comparing
    }

    struct EngineResult: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case waiting
            case running
            case succeeded
            case failed(String)
        }

        var state: State = .waiting
        var text = ""
        var latency: TimeInterval?
    }

    private enum ComparisonOutcome: Sendable {
        case onDevice(EngineResult)
        case server(EngineResult)
    }

    private(set) var preparationState = PreparationState.notStarted
    private(set) var capturePhase = CapturePhase.idle
    private(set) var recordedDuration: TimeInterval?
    private(set) var onDeviceResult = EngineResult()
    private(set) var serverResult = EngineResult()
    var errorMessage: String?

    @ObservationIgnored
    private let recorder = SpeechLabRecorder()
    @ObservationIgnored
    private var whisperKit: WhisperKit?
    @ObservationIgnored
    private var automaticStopTask: Task<Void, Never>?

    func prepareOnDeviceModel() async {
        guard preparationState != .preparing, preparationState != .ready else { return }
        preparationState = .preparing
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: Self.whisperKitModel,
                verbose: false,
                prewarm: true,
                load: true
            ))
            preparationState = .ready
        } catch {
            preparationState = .failed(error.localizedDescription)
        }
    }

    func startRecording(serverEndpoint: String) async {
        errorMessage = nil
        guard preparationState == .ready else { return }
        guard SpeechLabServer.validatedEndpoint(serverEndpoint) != nil else {
            errorMessage = SpeechLabError.invalidServerURL.localizedDescription
            return
        }
        guard await VisionDictationController.requestPermission() else {
            errorMessage = SpeechLabError.microphonePermissionDenied.localizedDescription
            return
        }

        do {
            try recorder.start()
            recordedDuration = nil
            onDeviceResult = EngineResult()
            serverResult = EngineResult()
            capturePhase = .recording
            automaticStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.maximumRecordingDuration))
                guard !Task.isCancelled, let self else { return }
                self.automaticStopTask = nil
                await self.stopAndCompare(serverEndpoint: serverEndpoint)
            }
        } catch {
            errorMessage = error.localizedDescription
            capturePhase = .idle
        }
    }

    func stopAndCompare(serverEndpoint: String) async {
        guard capturePhase == .recording else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil

        do {
            let recording = try recorder.stop()
            defer { try? FileManager.default.removeItem(at: recording.fileURL) }
            guard let endpoint = SpeechLabServer.validatedEndpoint(serverEndpoint) else {
                throw SpeechLabError.invalidServerURL
            }
            recordedDuration = recording.duration
            capturePhase = .comparing
            onDeviceResult = EngineResult(state: .running)
            serverResult = EngineResult(state: .running)

            await withTaskGroup(of: ComparisonOutcome.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        return .onDevice(EngineResult(
                            state: .failed("Speech Lab closed before transcription finished.")
                        ))
                    }
                    return .onDevice(await self.transcribeOnDevice(recording: recording))
                }
                group.addTask { [weak self] in
                    guard let self else {
                        return .server(EngineResult(
                            state: .failed("Speech Lab closed before transcription finished.")
                        ))
                    }
                    return .server(await self.transcribeOnServer(
                        recording: recording,
                        endpoint: endpoint
                    ))
                }

                for await outcome in group {
                    switch outcome {
                    case let .onDevice(result):
                        onDeviceResult = result
                    case let .server(result):
                        serverResult = result
                    }
                }
            }
            capturePhase = .idle
        } catch {
            errorMessage = error.localizedDescription
            capturePhase = .idle
        }
    }

    func discardRecording() {
        guard capturePhase == .recording else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil
        recorder.cancel()
        capturePhase = .idle
    }

    private func transcribeOnDevice(recording: SpeechLabRecording) async -> EngineResult {
        guard let whisperKit else {
            return EngineResult(state: .failed("The WhisperKit model is not loaded."))
        }
        let startedAt = Date()
        do {
            let results = try await whisperKit.transcribe(
                audioPath: recording.fileURL.path,
                decodeOptions: DecodingOptions(
                    language: nil,
                    temperature: 0,
                    detectLanguage: true,
                    withoutTimestamps: true
                )
            )
            let text = results
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return EngineResult(
                state: .succeeded,
                text: text,
                latency: Date().timeIntervalSince(startedAt)
            )
        } catch {
            return EngineResult(
                state: .failed(error.localizedDescription),
                latency: Date().timeIntervalSince(startedAt)
            )
        }
    }

    private func transcribeOnServer(
        recording: SpeechLabRecording,
        endpoint: URL
    ) async -> EngineResult {
        let startedAt = Date()
        do {
            let text = try await SpeechLabServer.transcribe(
                recording: recording,
                endpoint: endpoint
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return EngineResult(
                state: .succeeded,
                text: text,
                latency: Date().timeIntervalSince(startedAt)
            )
        } catch {
            return EngineResult(
                state: .failed(error.localizedDescription),
                latency: Date().timeIntervalSince(startedAt)
            )
        }
    }
}

struct SpeechComparisonLabView: View {
    @SwiftUI.Environment(AppModel.self) private var appModel
    @AppStorage("vision.speechLab.serverEndpoint") private var serverEndpoint = ""
    @State private var model = SpeechComparisonLabModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            configuration
            controls

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 16) {
                SpeechLabResultCard(
                    title: "On device",
                    subtitle: "WhisperKit · compressed Large v3 Turbo",
                    systemImage: "visionpro",
                    result: model.onDeviceResult
                )
                SpeechLabResultCard(
                    title: "Server",
                    subtitle: "whisper.cpp · Large v3 Turbo",
                    systemImage: "server.rack",
                    result: model.serverResult
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .navigationTitle("Speech Lab")
        .task {
            if serverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                serverEndpoint = suggestedServerEndpoint
            }
            await model.prepareOnDeviceModel()
        }
        .onDisappear {
            model.discardRecording()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speech Lab")
                .font(.largeTitle.bold())
            Text("Record once, then compare both engines against the exact same 16 kHz mono WAV.")
                .foregroundStyle(.secondary)
            Label(
                "Automatic language detection · temperature 0 · no contextual prompt",
                systemImage: "equal.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("http://server:8085/inference", text: $serverEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.capturePhase != .idle)
                preparationStatus
            }
            Text("For plain HTTP, use the server's numeric LAN or Tailscale address. Otherwise use an authenticated HTTPS proxy. The endpoint is saved only on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preparationStatus: some View {
        switch model.preparationState {
        case .notStarted, .preparing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing WhisperKit…")
            }
            .frame(minWidth: 210, alignment: .leading)
        case .ready:
            Label("WhisperKit ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(minWidth: 210, alignment: .leading)
        case let .failed(message):
            Button {
                Task { await model.prepareOnDeviceModel() }
            } label: {
                Label("Retry model setup", systemImage: "arrow.clockwise")
            }
            .help(message)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            switch model.capturePhase {
            case .idle:
                Button {
                    Task { await model.startRecording(serverEndpoint: serverEndpoint) }
                } label: {
                    Label("Record Sample", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.preparationState != .ready)
            case .recording:
                Button {
                    Task { await model.stopAndCompare(serverEndpoint: serverEndpoint) }
                } label: {
                    Label("Stop & Compare", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("Discard", role: .destructive) {
                    model.discardRecording()
                }
            case .comparing:
                ProgressView()
                Text("Transcribing both copies…")
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if let duration = model.recordedDuration {
                Text("Sample: \(duration.formatted(.number.precision(.fractionLength(1))))s")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if model.capturePhase == .recording {
                Text("Recording · stops automatically at 60s")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var suggestedServerEndpoint: String {
        guard let baseURL = appModel.environment?.httpBaseURL,
              let host = baseURL.host else { return "http://127.0.0.1:8085/inference" }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 8_085
        components.path = "/inference"
        return components.url?.absoluteString ?? "http://127.0.0.1:8085/inference"
    }
}

private struct SpeechLabResultCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let result: SpeechComparisonLabModel.EngineResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title3.bold())
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer()
                if let latency = result.latency {
                    Text("\(latency.formatted(.number.precision(.fractionLength(2))))s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Group {
                switch result.state {
                case .waiting:
                    ContentUnavailableView {
                        Label("No sample yet", systemImage: "waveform")
                    } description: {
                        Text("Record a phrase to see this transcript.")
                    }
                case .running:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Transcribing…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .succeeded:
                    ScrollView {
                        Text(result.text.isEmpty ? "No speech detected." : result.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Transcription failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
