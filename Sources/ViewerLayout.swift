import AppKit
import Combine
import SwiftUI

/// Sidebar and document side by side, with no divider between them. Built by
/// hand rather than with NavigationSplitView, which insists on drawing one.
struct ViewerView: View {
    @EnvironmentObject private var doc: DocumentModel
    @EnvironmentObject private var workspace: WorkspaceModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var storedWidth = ViewerView.sidebarDefaultWidth
    @State private var widthAtDragStart: CGFloat?
    @AppStorage("theme") private var themeName = AppTheme.system.rawValue
    @AppStorage("size") private var sizeName = "regular"
    @AppStorage("alignment") private var alignmentName = "justify"
    @AppStorage("measure") private var measureWidth = RenderPayload.defaultMeasure
    @State private var showSettings = false
    @State private var showFrontmatter = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebarWidthMigrated") private var widthMigrated = false

    // Layout zones, from the design: a 48pt titlebar band across the top, split
    // by a hairline at the sidebar's edge. The traffic lights (14pt, x=9…69 on
    // macOS 26) sit in the left half of that band.
    static let trafficLightSpan: CGFloat = 69
    /// Width of the left zone with the sidebar closed: the buttons, a full
    /// `--space-6` of air, then the toggle and its trailing inset. Sized rather
    /// than left to whatever a Spacer had spare, which was 11pt.
    static let collapsedZone: CGFloat = 69 + 27.6 + 26 + 13.8
    /// 52 so the traffic lights land in its centre: with an empty unified
    /// toolbar attached, macOS centres them 26pt from the top. Measured, not
    /// guessed — see DESIGN.md.
    static let titlebarHeight: CGFloat = 52
    static let sidebarDefaultWidth = Double(SidebarView.width)

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                name: doc.url?.lastPathComponent,
                meta: documentMeta,
                sidebarWidth: sidebarVisible ? storedWidth : ViewerView.collapsedZone,
                sidebarVisible: sidebarVisible,
                canCopy: Viewer.isMarkdown(doc.url),
                frontmatter: doc.frontmatter,
                showingFrontmatter: $showFrontmatter,
                palette: palette,
                toggleSidebar: toggleSidebar,
                openSettings: { showSettings = true }
            )
            .zIndex(2)

            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(workspace: workspace, doc: doc, palette: palette)
                        .frame(width: storedWidth)
                        .overlay(alignment: .trailing) { resizeHandle }
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(palette.divider).frame(width: 1)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }

                ViewerWebView(doc: doc, background: palette.bg)
                    .frame(minWidth: 420, minHeight: 320)
            }
        }
        .background(palette.bg)
        .overlay(alignment: .top) {
            if showFrontmatter, doc.url != nil {
                ZStack(alignment: .top) {
                    // Clicking anywhere else dismisses it, as in the design.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showFrontmatter = false }
                    FrontmatterPanel(frontmatter: doc.frontmatter, palette: palette)
                        .padding(.top, ViewerView.titlebarHeight + 6)
                        // The title is centred in the space right of the sidebar.
                        .offset(x: (sidebarVisible ? storedWidth : ViewerView.collapsedZone) / 2)
                        .onExitCommand { showFrontmatter = false }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if showSettings {
                SettingsSheet(
                    theme: $themeName,
                    size: $sizeName,
                    alignment: $alignmentName,
                    measure: $measureWidth,
                    effectiveTheme: colorScheme == .dark
                        ? AppTheme.night.rawValue : AppTheme.paper.rawValue,
                    palette: palette,
                    close: { showSettings = false },
                    settingsChanged: {
                        NotificationCenter.default.post(name: .mdvSettingsChanged, object: nil)
                    }
                )
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvToggleFrontmatter)) { _ in
            guard doc.url != nil else { return }
            showFrontmatter.toggle()
        }
        .onChange(of: doc.url) { _, _ in showFrontmatter = false }
        // The titlebar is transparent, so content owns the whole window frame.
        .ignoresSafeArea()
        // No focus rings on any control: this is a reading window, and SwiftUI
        // otherwise gives the header button focus at launch and draws a ring
        // around it. Inherited by every descendant.
        .focusEffectDisabled()
        .background(WindowChrome(background: palette.bg))
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
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            workspace.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvToggleSidebar)) { _ in
            toggleSidebar()
        }
    }

    private var palette: Palette {
        (AppTheme(rawValue: themeName) ?? .system).palette(dark: colorScheme == .dark)
    }

    /// The design shows a word count under the filename.
    private var documentMeta: String {
        guard doc.url != nil else { return "" }
        if let error = doc.loadError { return error }
        let words = doc.markdown.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        return words == 1 ? "1 word" : "\(words.formatted()) words"
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

/// The 48pt band across the top of the window.
///
/// Split by a hairline at the sidebar's edge: the traffic lights and the sidebar
/// toggle sit left of it, the document's name and word count centred right of
/// it. No filename in the real titlebar — that is hidden, so this is it.
struct TitleBar: View {
    let name: String?
    let meta: String
    let sidebarWidth: CGFloat
    let sidebarVisible: Bool
    let canCopy: Bool
    let frontmatter: Frontmatter
    @Binding var showingFrontmatter: Bool
    let palette: Palette
    let toggleSidebar: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            leftZone
            documentLabel
            if canCopy {
                CopyButton(palette: palette)
            }
            IconButton(symbol: "gearshape", palette: palette, action: openSettings)
                .help("Settings (⌘,)")
                .padding(.trailing, 13.8)
        }
        .frame(height: ViewerView.titlebarHeight)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    /// Holds the traffic lights, with the toggle at its inner edge.
    ///
    /// The padding goes inside the frame: applied outside it, the zone ends up
    /// wider than the sidebar and this hairline no longer lines up with the
    /// sidebar's own right edge below.
    private var leftZone: some View {
        HStack(spacing: 0) {
            Spacer(minLength: ViewerView.trafficLightSpan)
            IconButton(symbol: "sidebar.leading", palette: palette, action: toggleSidebar)
                .help("Toggle sidebar (⌘B)")
                .padding(.trailing, 13.8)
        }
        .frame(width: max(sidebarWidth, ViewerView.collapsedZone))
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.divider).frame(width: 1)
        }
    }

    /// Clickable when the document has frontmatter, and then it carries a caret
    /// and hangs the disclosure beneath itself.
    private var documentLabel: some View {
        let hasDocument = name != nil
        return VStack(spacing: 1) {
            Text(name ?? "No document")
                .font(Typeface.displayMatching(11.5))
                .tracking(0.13)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                if !meta.isEmpty {
                    Text(meta)
                        .font(Typeface.text(10))
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .lineLimit(1)
                }
                if hasDocument {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .rotationEffect(.degrees(showingFrontmatter ? 180 : 0))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(showingFrontmatter ? palette.accentText : palette.muted)
        }
        .padding(.horizontal, 13.8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        // Deliberately no hover fill. The design tints this with 10% accent, but
        // a gold wash across the titlebar is distracting on every mouse pass; the
        // caret is the affordance.
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasDocument else { return }
            showingFrontmatter.toggle()
        }
        .help(hasDocument ? "Front matter (⌘I)" : "")
    }
}

/// Copies the document's markdown, and says so for a moment afterwards.
struct CopyButton: View {
    let palette: Palette
    @State private var copied = false

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", palette: palette) {
            NotificationCenter.default.post(name: .mdvCopyDocument, object: nil)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        }
        .help(copied ? "Copied" : "Copy document (⌥⌘C)")
    }
}

/// A 26pt square, transparent until hovered, then a gold wash — the design's
/// only interactive chrome treatment.
struct IconButton: View {
    let symbol: String
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? palette.accentText : palette.muted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.accent.opacity(hovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    func apply(_ window: NSWindow?, background: NSColor? = nil) {
        let targets = window.map { [$0] } ?? NSApp.windows
        for target in targets where target.styleMask.contains(.titled) {
            // An empty unified toolbar is what moves the traffic lights down to
            // the centre of a taller band. Nothing is ever put in it.
            if target.toolbar == nil {
                let toolbar = NSToolbar(identifier: "mdview.titlebar")
                toolbar.showsBaselineSeparator = false
                target.toolbar = toolbar
            }
            if target.toolbarStyle != .unified { target.toolbarStyle = .unified }
            if !target.styleMask.contains(.fullSizeContentView) {
                target.styleMask.insert(.fullSizeContentView)
            }
            if !target.titlebarAppearsTransparent { target.titlebarAppearsTransparent = true }
            if target.titleVisibility != .hidden { target.titleVisibility = .hidden }
            if let background, target.backgroundColor != background {
                target.backgroundColor = background
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
        var buttonCentre = -1.0
        if let button = window.standardWindowButton(.closeButton),
            let frame = button.superview?.convert(button.frame, to: nil)
        {
            buttonCentre = window.frame.height - frame.maxY + frame.height / 2
        }
        let windowBackground =
            window.backgroundColor.usingColorSpace(.sRGB).map {
                String(
                    format: "#%02x%02x%02x", Int($0.redComponent * 255),
                    Int($0.greenComponent * 255), Int($0.blueComponent * 255))
            } ?? "none"
        return [
            "windowBg=\(windowBackground)",
            "buttonCentre=\(Int(buttonCentre.rounded()))",
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
    /// The window's own background shows at the frame's edges during a resize,
    /// and behind everything else. It has to be the theme's, not the system's.
    var background: Color = .clear

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowStyler.shared.apply(view.window, background: NSColor(background))
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            WindowStyler.shared.apply(view.window, background: NSColor(background))
        }
    }
}
