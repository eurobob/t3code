import SwiftUI

@main
struct T3VisionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.restore() }
        }
        .defaultSize(width: 1_120, height: 820)

        WindowGroup(id: "thread", for: String.self) { threadID in
            Group {
                if case .connected = model.phase, let threadID = threadID.wrappedValue {
                    NavigationStack {
                        ThreadDetailView(threadID: threadID)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Thread unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    } description: {
                        Text("Connect from the T3 Code window, then open this thread again.")
                    }
                }
            }
            .environment(model)
        }
        .defaultSize(width: 820, height: 780)
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
