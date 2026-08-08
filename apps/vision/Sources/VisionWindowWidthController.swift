import SwiftUI
import UIKit

/// Requests enough horizontal room for an optional trailing panel and restores
/// the compact workspace width when that panel closes.
struct VisionWindowWidthController: UIViewRepresentable {
    let isExpanded: Bool
    let expandedWidth: CGFloat
    let collapsedWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.update(
            view: view,
            isExpanded: isExpanded,
            expandedWidth: expandedWidth,
            collapsedWidth: collapsedWidth
        )
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(
            view: view,
            isExpanded: isExpanded,
            expandedWidth: expandedWidth,
            collapsedWidth: collapsedWidth
        )
    }

    @MainActor
    final class Coordinator {
        private var requestedWidth: CGFloat?

        func update(
            view: UIView,
            isExpanded: Bool,
            expandedWidth: CGFloat,
            collapsedWidth: CGFloat
        ) {
            let targetWidth = isExpanded ? expandedWidth : collapsedWidth
            guard requestedWidth != targetWidth else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let windowScene = view.window?.windowScene else { return }
                let currentWidth = view.window?.bounds.width ?? expandedWidth
                requestedWidth = targetWidth
                guard abs(currentWidth - targetWidth) > 1 else { return }
                let preferences = UIWindowScene.GeometryPreferences.Vision(
                    size: CGSize(
                        width: targetWidth,
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
