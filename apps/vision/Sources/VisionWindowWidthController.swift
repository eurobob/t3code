import SwiftUI
import UIKit

/// Requests enough horizontal room for an optional trailing panel. Closing the
/// panel leaves the user's window width alone instead of unexpectedly shrinking it.
struct VisionWindowWidthController: UIViewRepresentable {
    let isExpanded: Bool
    let expandedWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.update(
            view: view,
            isExpanded: isExpanded,
            expandedWidth: expandedWidth
        )
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(
            view: view,
            isExpanded: isExpanded,
            expandedWidth: expandedWidth
        )
    }

    @MainActor
    final class Coordinator {
        private var requestedExpansion = false

        func update(view: UIView, isExpanded: Bool, expandedWidth: CGFloat) {
            guard isExpanded else {
                requestedExpansion = false
                return
            }
            guard !requestedExpansion else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let windowScene = view.window?.windowScene else { return }
                let currentWidth = view.window?.bounds.width ?? expandedWidth
                let requestedWidth = max(currentWidth, expandedWidth)
                requestedExpansion = true
                guard abs(currentWidth - requestedWidth) > 1 else { return }
                let preferences = UIWindowScene.GeometryPreferences.Vision(
                    size: CGSize(
                        width: requestedWidth,
                        height: UIProposedSceneSizeNoPreference
                    ),
                    minimumSize: nil,
                    maximumSize: nil,
                    resizingRestrictions: nil
                )
                windowScene.requestGeometryUpdate(preferences)
            }
        }
    }
}
