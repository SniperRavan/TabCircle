#if os(macOS)
import SwiftUI

@available(macOS 13.0, *)
public struct PermissionFlowButton: View {
    @Environment(\.locale) var locale
    @StateObject private var controller: PermissionFlowController
    private let pane: PermissionFlowPane
    private let suggestedAppURLs: [URL]
    private let title: LocalizedStringResource?

    public init(
        title: LocalizedStringResource? = nil,
        pane: PermissionFlowPane,
        suggestedAppURLs: [URL] = [],
        configuration: PermissionFlowConfiguration = .init()
    ) {
        _controller = StateObject(wrappedValue: PermissionFlowController(configuration: configuration))
        self.pane = pane
        self.suggestedAppURLs = suggestedAppURLs
        self.title = title
    }

    public var body: some View {
        Button {
            controller.setLocaleIdentifier(locale.identifier)
            controller.authorize(
                pane: pane,
                suggestedAppURLs: suggestedAppURLs,
                sourceFrameInScreen: clickSourceFrameInScreen()
            )
        } label: {
            if let title {
                Text(String(localized: title))
            } else {
                Text(String(localized: LocalizedStringResource("permission_flow.button.grant", locale: locale, bundle: .atURL(Bundle.permissionFlowResources.bundleURL))))
            }
        }
    }

    /// Uses the exact click location as the launch point so the panel appears
    /// to fly out from where the user pressed the button.
    private func clickSourceFrameInScreen() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
    }
}
#endif
