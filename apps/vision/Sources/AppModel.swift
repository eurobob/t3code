import ClerkKit
import Foundation
import Observation

/// Owns the connection for the whole app.
///
/// Deliberately thin: `T3ConnectController`, `EnvironmentRuntime` and `T3Client`
/// come straight from apps/swift-ios and already handle Clerk sign-in, the relay
/// handshake, DPoP credential exchange, credential storage and RPC. This only
/// adapts them to SwiftUI's observation model.
@MainActor
@Observable
final class AppModel {
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
                for try await _ in stream {
                    if Task.isCancelled { return }
                    guard let refreshed = try? await client.shellSnapshot() else { continue }
                    await MainActor.run { self?.snapshot = refreshed }
                }
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func disconnect() async {
        eventsTask?.cancel()
        eventsTask = nil
        await client?.disconnect()
        client = nil
        snapshot = nil
        environment = nil
        phase = account == nil ? .signedOut : .choosingEnvironment
    }

    func signOut() async {
        await disconnect()
        await connect.signOut()
        account = nil
        cloudEnvironments = []
        phase = .signedOut
    }
}
