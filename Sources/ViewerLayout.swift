import SwiftUI
import AppKit
import Combine

/// Sidebar and document side by side, with no divider between them. Built by
/// hand rather than with NavigationSplitView, which insists on drawing one.
struct ViewerView: View {
    @EnvironmentObject private var doc: DocumentModel
    @EnvironmentObject private var workspace: WorkspaceModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var storedWidth = ViewerView.sidebarDefaultWidth
    @State private var widthAtDragStart: CGFloat?
    @AppStorage("sidebarWidthMigrated") private var widthMigrated = false

    // Layout zones — see DESIGN.md. Measured on macOS 26: the traffic lights are
    // 14pt, span x=9…69, bottom edge at 23pt. They get a band of their own;
    // chrome content clears it rather than aligning into it.
    static let trafficLightSpan: CGFloat = 69
    static let reservedTopBand: CGFloat = 44
    static let headerHeight: CGFloat = 56
    static let sidebarTopInset: CGFloat = 60
    static let sidebarDefaultWidth = 264.0

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(workspace: workspace, doc: doc, topInset: ViewerView.sidebarTopInset)
                    .frame(width: storedWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }

            VStack(spacing: 0) {
                DocumentHeader(
                    name: doc.url?.lastPathComponent,
                    folder: folder,
                    leadingInset: sidebarVisible ? 16 : ViewerView.trafficLightSpan + 16,
                    toggleSidebar: toggleSidebar
                )
                ViewerWebView(doc: doc)
            }
            .frame(minWidth: 420, minHeight: 320)
        }
        // The titlebar is transparent, so content owns the whole window frame.
        .ignoresSafeArea()
        // No focus rings on any control: this is a reading window, and SwiftUI
        // otherwise gives the header button focus at launch and draws a ring
        // around it. Inherited by every descendant.
        .focusEffectDisabled()
        .background(WindowChrome())
        .onAppear {
            // The old default (238) was set before DESIGN.md; move anyone still on
            // it to the new one. A width the user actually chose is left alone.
            if !widthMigrated {
                widthMigrated = true
                if storedWidth == 238.0 { storedWidth = ViewerView.sidebarDefaultWidth }
            }
        }
        .navigationTitle(doc.url?.lastPathComponent ?? "MDView")
        .onChange(of: doc.url) { _, url in
            if let url { workspace.reveal(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvToggleSidebar)) { _ in
            toggleSidebar()
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { sidebarVisible.toggle() }
    }

    /// A wide-enough grab area sitting on the seam, drawing nothing.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? storedWidth
                        if widthAtDragStart == nil { widthAtDragStart = storedWidth }
                        storedWidth = min(max(start + value.translation.width, 170), 460)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }

    /// The containing folder, with $HOME shortened to "~".
    private var folder: String {
        guard let dir = doc.url?.deletingLastPathComponent().path else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// The filename, now that the titlebar no longer shows it. No bottom border —
/// it shares the document's background and reads as part of the page.
struct DocumentHeader: View {
    let name: String?
    let folder: String
    let leadingInset: CGFloat
    let toggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle sidebar (⌘B)")

            if let name {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 16)
        // Tall enough that the row's content sits below the traffic lights rather
        // than between them — see DESIGN.md, "The traffic-light band".
        .frame(height: ViewerView.headerHeight)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The titlebar treatment that lets content run to the top of the window.
///
/// In the app this is done by `.windowStyle(.hiddenTitleBar)` on the scene —
/// setting the AppKit properties by hand does not survive SwiftUI's own titlebar
/// setup. `apply` exists for the offscreen design tools, which build their own
/// windows with no SwiftUI scene to configure them.
@MainActor
final class WindowStyler {
    static let shared = WindowStyler()

    func apply(_ window: NSWindow?) {
        let targets = window.map { [$0] } ?? NSApp.windows
        for target in targets where target.styleMask.contains(.titled) {
            if !target.styleMask.contains(.fullSizeContentView) {
                target.styleMask.insert(.fullSizeContentView)
            }
            if !target.titlebarAppearsTransparent { target.titlebarAppearsTransparent = true }
            if target.titleVisibility != .hidden { target.titleVisibility = .hidden }
            if target.backgroundColor != .textBackgroundColor {
                target.backgroundColor = .textBackgroundColor
            }
        }
    }

    /// Reports what actually stuck, for `tools/check-window-chrome.sh`.
    func describe() -> String {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else {
            return "no titled window"
        }
        let content = window.contentView?.frame ?? .zero
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        return [
            "firstResponder=\(responder)",
            "titleVisibility=\(window.titleVisibility == .hidden ? "hidden" : "visible")",
            "fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))",
            "titlebarTransparent=\(window.titlebarAppearsTransparent)",
            "contentHeight=\(Int(content.height))",
            "windowHeight=\(Int(window.frame.height))",
        ].joined(separator: " ")
    }
}

/// Applies the chrome for whichever window hosts this view.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { WindowStyler.shared.apply(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { WindowStyler.shared.apply(view.window) }
    }
}

