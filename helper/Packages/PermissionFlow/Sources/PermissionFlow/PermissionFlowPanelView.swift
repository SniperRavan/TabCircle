#if os(macOS)
import SwiftUI

@available(macOS 13.0, *)
struct PermissionFlowPanelView: View {
    @ObservedObject var controller: PermissionFlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let hint = controller.panelHint, hint.isEmpty == false {
                hintBanner(hint)
            }
            if let primaryApp = controller.preferredAppURL {
                AppDragItemView(url: primaryApp) { isDragging in
                    controller.setPanelDragging(isDragging)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.primary.opacity(0.14), lineWidth: 1)
                )
        )
    }

    /// Renders the host-supplied hint as a subtle warning banner so the user
    /// notices the extra step (e.g. removing the existing entry first) before
    /// they start dragging.
    private func hintBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        )
    }

    /// Keeps the header logic isolated from the drag card layout.
    private var header: some View {
        HStack(alignment: .top, spacing: 3) {
            HeaderDirectionIcon(isDragging: controller.isDraggingApp)
            if let title = controller.panelTitle, title.isEmpty == false {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            } else {
                Text("permission_flow.panel.title", bundle: .permissionFlowResources)
                    .font(.system(size: 16, weight: .semibold))
            }
            Spacer()
            HStack(alignment: .top, spacing: 3) {
                if controller.isSettingsFrontmost == false {
                    Button {
                        controller.reopenCurrentSettingsPane()
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.primary, .secondary.opacity(0.35))
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    controller.closePanel(returnToPreviousApp: true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.primary, .secondary.opacity(0.35))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

@available(macOS 13.0, *)
private struct HeaderDirectionIcon: View {
    let isDragging: Bool

    @State private var wigglePhase = false
    @State private var scalePhase = false

    var body: some View {
        Image(systemName: "arrowshape.up.fill")
            .font(.system(size: 14, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .rotationEffect(.degrees(isDragging ? 0 : (wigglePhase ? 12 : -12)))
            .offset(y: isDragging ? 0 : (wigglePhase ? -2 : 1))
            .scaleEffect(isDragging ? (scalePhase ? 1.18 : 0.88) : 1)
            .animation(
                isDragging
                    ? .easeInOut(duration: 0.68).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.22).repeatForever(autoreverses: true),
                value: isDragging ? scalePhase : wigglePhase
            )
            .onAppear {
                wigglePhase = true
            }
            .onChange(of: isDragging) { dragging in
                if dragging {
                    scalePhase = true
                    wigglePhase = false
                } else {
                    scalePhase = false
                    wigglePhase = true
                }
            }
    }
}
#endif
