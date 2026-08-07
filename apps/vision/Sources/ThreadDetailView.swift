import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadDetailModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let threadID: String

    private(set) var loadState: LoadState = .loading
    private(set) var detail: OrchestrationThreadDetailSnapshot?
    private(set) var liveError: String?

    @ObservationIgnored
    private var eventsTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshGeneration = 0

    init(threadID: String) {
        self.threadID = threadID
    }

    var thread: OrchestrationThread? { detail?.thread }

    var transcriptRevision: String {
        guard let last = thread?.messages.last else { return "empty" }
        return "\(last.id):\(last.updatedAt):\(last.text.count):\(last.streaming)"
    }

    func start(using appModel: AppModel) async {
        guard eventsTask == nil else { return }
        loadState = .loading
        do {
            let snapshot = try await appModel.threadSnapshot(id: threadID)
            apply(snapshot)
            loadState = .loaded
            startEvents(after: snapshot.snapshotSequence, using: appModel)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func startEvents(after sequence: Int, using appModel: AppModel) {
        eventsTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            do {
                let stream = try await appModel.threadEvents(
                    threadID: threadID,
                    after: sequence
                )
                for try await item in stream {
                    try Task.checkCancellation()
                    switch item {
                    case .synchronized:
                        liveError = nil
                    case let .snapshot(snapshot):
                        apply(snapshot)
                    case .event:
                        scheduleRefresh(using: appModel)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                liveError = "Live updates paused: \(error.localizedDescription)"
            }
        }
    }

    /// The stream carries compact domain events rather than rebuilt threads.
    /// Coalesce token and tool bursts into authoritative detail reads so this
    /// small client stays correct without duplicating the upstream reducer.
    private func scheduleRefresh(using appModel: AppModel) {
        refreshGeneration &+= 1
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            while !Task.isCancelled {
                let targetGeneration = refreshGeneration
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    try Task.checkCancellation()
                    let snapshot = try await appModel.threadSnapshot(id: threadID)
                    apply(snapshot)
                    liveError = nil
                } catch is CancellationError {
                    return
                } catch {
                    liveError = "Could not refresh this thread: \(error.localizedDescription)"
                }

                guard targetGeneration != refreshGeneration else {
                    refreshTask = nil
                    return
                }
            }
        }
    }

    private func apply(_ snapshot: OrchestrationThreadDetailSnapshot) {
        guard snapshot.snapshotSequence >= (detail?.snapshotSequence ?? 0) else { return }
        detail = snapshot
    }
}

struct ThreadDetailView: View {
    @SwiftUI.Environment(AppModel.self) private var appModel
    @State private var model: ThreadDetailModel

    init(threadID: String) {
        _model = State(initialValue: ThreadDetailModel(threadID: threadID))
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Loading thread…")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Could not load thread", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded:
                transcript
            }
        }
        .navigationTitle(model.thread?.title ?? "Thread")
        .task { await model.start(using: appModel) }
        .onDisappear { model.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let error = model.liveError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    ForEach(model.thread?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: model.transcriptRevision) {
                guard let id = model.thread?.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .task(id: model.thread?.id) {
                await Task.yield()
                guard let id = model.thread?.messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: OrchestrationMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(message.role.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if message.streaming {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Streaming")
                }
            }

            if message.text.isEmpty {
                Text(message.streaming ? "Thinking…" : "No text")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(message.text)
                    .textSelection(.enabled)
            }

            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    Label(attachment.name, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
