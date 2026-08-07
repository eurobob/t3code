import ClerkKit
import SwiftUI

/// T3 Connect sign-in.
///
/// The iOS client now uses Clerk's prebuilt `AuthView`, but that is gated
/// `#if os(iOS) || os(macOS)` inside ClerkKitUI — it does not exist on
/// visionOS. `signInWithOAuth` is not gated, so this drives the same flow with
/// its own buttons.
///
/// Deliberately no Apple button: the iOS client calls native
/// `signInWithApple()`, which binds to the bundle identifier and would be
/// rejected for this fork. The web OAuth providers redirect to
/// `t3code-swiftui://clerk-callback`, derived from `PlatformRoute.nativeScheme`,
/// which is the string Clerk validates — and is bundle-independent.
struct SignInView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    private let providers: [(provider: OAuthProvider, title: String)] = [
        (.google, "Continue with Google"),
        (.github, "Continue with GitHub"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("T3 Vision")
                    .font(.largeTitle.weight(.semibold))
                Text("Sign in to T3 Connect to see your environments.")
                    .foregroundStyle(.secondary)
            }

            if let reason = model.unavailableReason {
                ContentUnavailableView(
                    "T3 Connect unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(reason)
                )
            } else if model.phase == .signingIn {
                ProgressView("Signing in…")
            } else {
                VStack(spacing: 12) {
                    ForEach(providers, id: \.title) { entry in
                        Button(entry.title) {
                            Task { await model.signIn(with: entry.provider) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Divider().frame(maxWidth: 320)

            // Direct pairing stays available alongside Connect — it is the path
            // that works without any relay or Clerk configuration at all.
            PairingView()
        }
        .padding(40)
    }
}

/// Environments linked to the signed-in account — the reason to use T3 Connect
/// rather than pairing: they simply appear.
struct EnvironmentPickerView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.cloudEnvironments.isEmpty {
                    ContentUnavailableView(
                        "No linked environments",
                        systemImage: "server.rack",
                        description: Text("Run `t3 connect` on a machine to link it to your account.")
                    )
                } else {
                    List(model.cloudEnvironments) { cloud in
                        Button {
                            Task { await model.connectTo(cloud) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cloud.environment.label)
                                    .font(.headline)
                                if let status = cloud.status {
                                    let isOnline = status.status == .online
                                    Text(isOnline ? "Online" : "Offline")
                                        .font(.caption)
                                        .foregroundStyle(
                                            isOnline ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
                                        )
                                } else if let error = cloud.statusError {
                                    Text(error).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Environments")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
            }
        }
    }
}
