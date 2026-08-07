import SwiftUI

@main
struct T3VisionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // The hub. One window per thread is the headline spatial idea, but this
        // spike deliberately stops at proving the transport — see README.
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.restore() }
        }
        .defaultSize(width: 720, height: 900)
    }
}

struct RootView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .signedOut, .signingIn:
            SignInView()
        case .choosingEnvironment:
            EnvironmentPickerView()
        case .connecting:
            ProgressView("Connecting…")
        case .connected:
            ThreadListView()
        case let .failed(message):
            ContentUnavailableView {
                Label("Could not connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Back") { Task { await model.disconnect() } }
            }
        }
    }
}
