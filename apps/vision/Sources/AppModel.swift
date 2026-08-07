import ClerkKit
import Foundation
import Observation

struct VisionModelOption: Identifiable, Equatable {
    let providerName: String
    let modelName: String
    let selection: ModelSelection

    var id: String { "\(selection.instanceId):\(selection.model)" }
    var label: String { "\(providerName) · \(modelName)" }
}

/// Owns the connection for the whole app.
///
/// Deliberately thin: `T3ConnectController`, `EnvironmentRuntime` and `T3Client`
/// come straight from apps/swift-ios and already handle Clerk sign-in, the relay
/// handshake, DPoP credential exchange, credential storage and RPC. This only
/// adapts them to SwiftUI's observation model.
@MainActor
@Observable
final class AppModel {
    enum ClientError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                "T3 Vision is not connected to an environment."
            }
        }
    }

    enum Phase: Equatable {
        case signedOut
        case signingIn
        case choosingEnvironment
        case connecting
        case connected
        case failed(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var account: T3ConnectAccount?
    private(set) var cloudEnvironments: [T3ConnectCloudEnvironment] = []
    private(set) var environment: Environment?
    private(set) var snapshot: OrchestrationShellSnapshot?
    private(set) var archivedThreads: [OrchestrationThreadShell] = []
    private(set) var serverConfig: ServerConfigSnapshot?
    private(set) var threadOrder: [String] = []

    let connect = T3ConnectController()

    private let credentialStore = KeychainCredentialStore(
        service: "codes.t3.vision.environment-credentials"
    )
    // @Observable rewrites stored properties into computed ones, which `lazy`
    // cannot coexist with — and this is plumbing the UI never observes anyway.
    @ObservationIgnored
    private lazy var runtime = EnvironmentRuntime(
        environmentStore: EnvironmentStore(),
        credentialStore: credentialStore,
        managedAuthorization: T3ConnectRuntimeAuthorization(controller: connect)
    )
    private var client: T3Client?
    private var eventsTask: Task<Void, Never>?
    private var configEventsTask: Task<Void, Never>?

    @ObservationIgnored
    private lazy var pairingService = PairingService(
        environmentStore: EnvironmentStore(),
        credentialStore: credentialStore
    )

    /// Pairs directly with a server, bypassing T3 Connect. See PairingView for
    /// why this is currently the working path.
    func pair(pairingURL: String) async {
        phase = .connecting
        do {
            let paired = try await pairingService.pair(url: pairingURL, label: "T3 Vision")
            await adopt(paired)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    var unavailableReason: String? { connect.unavailableReason }

    var availableModels: [VisionModelOption] {
        let configured = (serverConfig?.providers ?? []).flatMap { provider -> [VisionModelOption] in
            guard provider.enabled,
                  provider.installed,
                  provider.status != "disabled",
                  provider.status != "error",
                  provider.auth.status != "unauthenticated",
                  provider.availability != "unavailable" else { return [] }
            let providerName = provider.displayName ?? provider.driver
            return provider.models
                .filter { $0.isLegacy != true }
                .map { model in
                    VisionModelOption(
                        providerName: providerName,
                        modelName: model.shortName ?? model.name,
                        selection: ModelSelection(
                            instanceId: provider.instanceId,
                            model: model.slug
                        )
                    )
                }
        }
        if serverConfig?.providers.isEmpty == false { return configured }

        var seen: Set<String> = []
        let selections = (snapshot?.projects.compactMap(\.defaultModelSelection) ?? [])
            + (snapshot?.threads.map(\.modelSelection) ?? [])
        return selections.compactMap { selection in
            let id = "\(selection.instanceId):\(selection.model)"
            guard seen.insert(id).inserted else { return nil }
            return VisionModelOption(
                providerName: selection.instanceId,
                modelName: selection.model,
                selection: selection
            )
        }
    }

    var dictationVocabulary: [String] {
        let staticTerms = [
            "Codex", "Claude", "Claude Code", "Cursor", "Grok", "OpenCode",
            "T3", "T3 Code", "thread", "worktree", "checkpoint", "pull request",
            "rebase", "monorepo", "TypeScript", "Swift", "Kotlin",
        ]
        var dynamicTerms: [String] = []
        for project in snapshot?.projects ?? [] {
            dynamicTerms.append(project.title)
            dynamicTerms.append(
                URL(fileURLWithPath: project.workspaceRoot).lastPathComponent
            )
        }
        for thread in (snapshot?.threads ?? []).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            dynamicTerms.append(thread.title)
            if let branch = thread.branch {
                dynamicTerms.append(branch)
                dynamicTerms.append(branch.replacingOccurrences(
                    of: "[/_.-]+",
                    with: " ",
                    options: .regularExpression
                ))
            }
        }

        var seen: Set<String> = []
        return (staticTerms + Array(dynamicTerms.prefix(200))).compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.count <= 80 else { return nil }
            guard seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    /// Restores a previously connected environment, falling back to whatever
    /// stage of sign-in the user is actually at.
    func restore() async {
        await connect.refresh()
        account = connect.account
        cloudEnvironments = connect.environments

        if account == nil {
            phase = .signedOut
            return
        }

        if let saved = try? await runtime.environments(), let existing = saved.first {
            await adopt(existing)
            return
        }
        phase = .choosingEnvironment
    }

    /// Drives Clerk's OAuth flow directly, since ClerkKitUI's `AuthView` is
    /// iOS/macOS-only and unavailable on visionOS.
    func signIn(with provider: OAuthProvider) async {
        guard let clerk = connect.clerk else {
            phase = .failed(connect.unavailableReason ?? "T3 Connect is not configured in this build.")
            return
        }
        phase = .signingIn
        do {
            _ = try await clerk.auth.signInWithOAuth(provider: provider)
            _ = try await clerk.refreshClient()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await refreshSession()
    }

    func refreshSession() async {
        await connect.refresh()
        account = connect.account
        cloudEnvironments = connect.environments
        if let message = connect.errorMessage {
            connect.errorMessage = nil
            phase = .failed(message)
            return
        }
        phase = account == nil ? .signedOut : .choosingEnvironment
    }

    /// Exchanges the relay's one-use bootstrap credential for a DPoP-bound
    /// session, then connects. Mirrors NativeFeatureClient's managed flow — the
    /// descriptor is re-read from the endpoint so a relay record that points at
    /// the wrong environment is caught before anything is persisted.
    func connectTo(_ cloud: T3ConnectCloudEnvironment) async {
        phase = .connecting
        do {
            let credential = try await connect.credential(for: cloud.environment)
            guard
                let httpBaseURL = URL(string: credential.endpoint.httpBaseUrl),
                let webSocketBaseURL = URL(string: credential.endpoint.wsBaseUrl)
            else {
                phase = .failed("The relay returned an endpoint this build could not parse.")
                return
            }

            let descriptor = try await runtime.descriptor(at: httpBaseURL)
            guard descriptor.environmentId == credential.environmentID else {
                phase = .failed("The environment at that endpoint did not match the relay record.")
                return
            }

            let authorization = try await connect.managedAuthorizer.exchange(
                credential,
                clientLabel: "T3 Vision"
            )
            let environment = Environment(
                id: descriptor.environmentId,
                label: descriptor.label,
                httpBaseURL: httpBaseURL,
                webSocketBaseURL: webSocketBaseURL,
                kind: .managedDPoP,
                descriptor: descriptor
            )
            _ = try await runtime.saveManagedEnvironment(
                environment,
                credential: .managedDPoP(
                    accessToken: authorization.accessToken,
                    expiresAt: authorization.expiresAt,
                    scopes: authorization.scopes,
                    environmentID: authorization.environmentID,
                    proofKeyThumbprint: authorization.proofKeyThumbprint
                )
            )
            await adopt(environment)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func adopt(_ environment: Environment) async {
        self.environment = environment
        phase = .connecting

        let client = T3Client(
            environment: environment,
            credentialStore: credentialStore,
            managedAuthorization: T3ConnectRuntimeAuthorization(controller: connect)
        )
        self.client = client
        await client.connect()

        do {
            snapshot = try await client.shellSnapshot()
            archivedThreads = (try? await client.archivedShellSnapshot().threads) ?? []
            serverConfig = try? await client.serverConfig()
            threadOrder = UserDefaults.standard.stringArray(
                forKey: threadOrderKey(environmentID: environment.id)
            ) ?? []
            phase = .connected
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // The snapshot is a point-in-time read; the event stream is what keeps
        // the window live as agents work. Re-reading the whole snapshot per
        // event is wasteful but correct, and correctness is what this spike is
        // proving — incremental reducers can come later.
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let stream = await client.shellEvents()
            do {
                for try await item in stream {
                    if Task.isCancelled { return }
                    guard let refreshed = try? await client.shellSnapshot() else { continue }
                    var archived: [OrchestrationThreadShell]?
                    var restoredThreadID: String?
                    if case .threadRemoved(_, _) = item {
                        archived = try? await client.archivedShellSnapshot().threads
                    } else if case let .threadUpserted(_, thread) = item {
                        restoredThreadID = thread.id
                    }
                    await MainActor.run {
                        self?.snapshot = refreshed
                        if let archived { self?.archivedThreads = archived }
                        if let restoredThreadID {
                            self?.archivedThreads.removeAll { $0.id == restoredThreadID }
                        }
                    }
                }
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }

        configEventsTask?.cancel()
        configEventsTask = Task { [weak self] in
            do {
                for try await item in await client.serverConfigEvents() {
                    if Task.isCancelled { return }
                    await MainActor.run { self?.applyServerConfigEvent(item) }
                }
            } catch {
                // Creation keeps using the last catalog; reconnecting the Core
                // subscription will refresh it when the socket returns.
            }
        }
    }

    func disconnect() async {
        eventsTask?.cancel()
        eventsTask = nil
        configEventsTask?.cancel()
        configEventsTask = nil
        await client?.disconnect()
        client = nil
        snapshot = nil
        archivedThreads = []
        serverConfig = nil
        threadOrder = []
        environment = nil
        phase = account == nil ? .signedOut : .choosingEnvironment
    }

    func threadSnapshot(id: String) async throws -> OrchestrationThreadDetailSnapshot {
        guard let client else { throw ClientError.notConnected }
        return try await client.threadSnapshot(id: id)
    }

    func threadEvents(
        threadID: String,
        after sequence: Int
    ) async throws -> AsyncThrowingStream<ThreadStreamItem, Error> {
        guard let client else { throw ClientError.notConnected }
        return await client.threadEvents(threadID: threadID, after: sequence)
    }

    func sendTurn(
        thread: OrchestrationThread,
        text: String
    ) async throws -> DispatchResult {
        guard let client else { throw ClientError.notConnected }
        return try await client.sendTurn(
            threadID: thread.id,
            text: text,
            runtimeMode: thread.runtimeMode,
            interactionMode: thread.interactionMode
        )
    }

    func interrupt(threadID: String, turnID: String?) async throws -> DispatchResult {
        guard let client else { throw ClientError.notConnected }
        return try await client.interrupt(threadID: threadID, turnID: turnID)
    }

    func createThreadAndSend(
        projectID: String,
        title: String,
        text: String,
        model: ModelSelection,
        runtimeMode: RuntimeMode,
        interactionMode: InteractionMode
    ) async throws -> String {
        guard let client else { throw ClientError.notConnected }
        let threadID = UUID().uuidString
        _ = try await client.createThreadAndSend(
            threadID: threadID,
            projectID: projectID,
            title: title,
            text: text,
            model: model,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode
        )
        return threadID
    }

    func createProject(
        title: String,
        workspaceRoot: String,
        defaultModel: ModelSelection?,
        createWorkspaceRootIfMissing: Bool
    ) async throws {
        guard let client else { throw ClientError.notConnected }
        _ = try await client.createProject(
            title: title,
            workspaceRoot: workspaceRoot,
            defaultModel: defaultModel,
            createWorkspaceRootIfMissing: createWorkspaceRootIfMissing
        )
    }

    func pin(threadID: String, pinned: Bool) async throws {
        guard let client else { throw ClientError.notConnected }
        _ = try await client.pin(threadID: threadID, pinned: pinned)
    }

    func settle(threadID: String, settled: Bool) async throws {
        guard let client else { throw ClientError.notConnected }
        _ = try await client.settle(threadID: threadID, settled: settled)
    }

    func rename(threadID: String, title: String) async throws {
        guard let client else { throw ClientError.notConnected }
        _ = try await client.rename(threadID: threadID, title: title)
    }

    func archive(threadID: String, archived: Bool) async throws {
        guard let client else { throw ClientError.notConnected }
        _ = try await client.archive(threadID: threadID, archived: archived)
        archivedThreads = (try? await client.archivedShellSnapshot().threads) ?? archivedThreads
        snapshot = (try? await client.shellSnapshot()) ?? snapshot
    }

    func setThreadOrder(_ orderedIDs: [String]) {
        let moved = Set(orderedIDs)
        threadOrder.removeAll { moved.contains($0) }
        threadOrder.append(contentsOf: orderedIDs)
        guard let environment else { return }
        UserDefaults.standard.set(
            threadOrder,
            forKey: threadOrderKey(environmentID: environment.id)
        )
    }

    func defaultModel(for project: OrchestrationProject) -> ModelSelection? {
        if let selection = project.defaultModelSelection,
           isAvailable(selection) {
            return selection
        }
        if let recent = snapshot?.threads
            .filter({ $0.projectId == project.id })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first?.modelSelection,
           isAvailable(recent) {
            return recent
        }
        let providers = serverConfig?.providers ?? []
        for provider in providers where provider.enabled && provider.installed {
            if let model = provider.models.first(where: { $0.isDefault == true }),
               let option = availableModels.first(where: {
                   $0.selection.instanceId == provider.instanceId
                       && $0.selection.model == model.slug
               }) {
                return option.selection
            }
        }
        return availableModels.first?.selection
    }

    func signOut() async {
        await disconnect()
        await connect.signOut()
        account = nil
        cloudEnvironments = []
        phase = .signedOut
    }

    private func applyServerConfigEvent(_ event: ServerConfigStreamEvent) {
        switch event {
        case let .snapshot(config):
            serverConfig = config
        case let .providerStatuses(providers):
            serverConfig = ServerConfigSnapshot(
                providers: providers,
                settings: serverConfig?.settings,
                threadSnapshotPagination: serverConfig?.threadSnapshotPagination
            )
        case let .settingsUpdated(settings):
            serverConfig = ServerConfigSnapshot(
                providers: serverConfig?.providers ?? [],
                settings: settings,
                threadSnapshotPagination: serverConfig?.threadSnapshotPagination
            )
        case .unrelated:
            break
        }
    }

    private func threadOrderKey(environmentID: String) -> String {
        "codes.t3.vision.thread-order.\(environmentID)"
    }

    private func isAvailable(_ selection: ModelSelection) -> Bool {
        availableModels.contains {
            $0.selection.instanceId == selection.instanceId
                && $0.selection.model == selection.model
        }
    }
}
