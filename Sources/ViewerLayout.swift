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
    @AppStorage("outlineWidth") private var outlineWidth = ViewerView.outlineDefaultWidth
    @AppStorage("theme") private var themeName = AppTheme.system.rawValue
    @AppStorage("size") private var sizeName = "regular"
    @AppStorage("alignment") private var alignmentName = "justify"
    @AppStorage("measure") private var measureWidth = RenderPayload.defaultMeasure
    @State private var rowWidth: CGFloat = 0
    @State private var showSettings = false
    @State private var showFrontmatter = false
    @State private var showShortcuts = false
    /// Reported by the page: an input in there has focus, so plain keys are its
    /// own. See the `pageFocus` message in web/src/viewer.js.
    @State private var pageInputFocused = false
    @AppStorage("outlineVisible") private var outlineVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebarWidthMigrated") private var widthMigrated = false

    // Layout zones, from the design: a 52pt titlebar band across the top, split
    // by a hairline at the sidebar's edge. The traffic lights (14pt, x=9…69 on
    // macOS 26) sit in the left half of that band.
    static let trafficLightSpan: CGFloat = 69
    /// Width of the left zone with the sidebar closed: the buttons, a full
    /// `--space-6` of air, then the toggle and its trailing inset. Sized rather
    /// than left to whatever a Spacer had spare, which was 11pt.
    static let collapsedZone: CGFloat = 69 + 27.6 + IconButton.size + 13.8
    /// 52 so the traffic lights land in its centre: with an empty unified
    /// toolbar attached, macOS centres them 26pt from the top. Measured, not
    /// guessed — see DESIGN.md.
    static let titlebarHeight: CGFloat = 52
    static let sidebarDefaultWidth = Double(SidebarView.width)
    static let sidebarWidthRange: ClosedRange<Double> = 170...460
    static let outlineDefaultWidth = Double(OutlinePanel.defaultWidth)
    /// Narrower floor than the sidebar's: the deepest heading indent plus room
    /// for a word or two of its title.
    static let outlineWidthRange: ClosedRange<Double> = 160...460
    /// The document never gets squeezed below this, whatever the panels want.
    static let documentMinWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                name: doc.url?.lastPathComponent,
                meta: documentMeta,
                sidebarWidth: sidebarVisible ? sidebarWidth : ViewerView.collapsedZone,
                sidebarVisible: sidebarVisible,
                canCopy: Viewer.hasCopyableSource(doc.url),
                outlineOpen: outlineVisible,
                toggleOutline: toggleOutline,
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
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(palette.divider).frame(width: 1)
                        }
                        .overlay(alignment: .trailing) {
                            ResizeHandle(
                                width: $storedWidth, edge: .trailing,
                                range: ViewerView.sidebarWidthRange.lowerBound...sidebarLimit)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }

                ViewerWebView(doc: doc, background: palette.bg)
                    .frame(minWidth: ViewerView.documentMinWidth, minHeight: 320)

                if outlineVisible {
                    OutlinePanel(
                        outline: doc.outline, palette: palette, width: contentsWidth
                    ) { index in
                        NotificationCenter.default.post(
                            name: .mdvScrollToHeading, object: index as NSNumber)
                    }
                    .overlay(alignment: .leading) {
                        Rectangle().fill(palette.divider).frame(width: 1)
                    }
                    .overlay(alignment: .leading) {
                        ResizeHandle(
                            width: $outlineWidth, edge: .leading,
                            range: ViewerView.outlineWidthRange.lowerBound...contentsLimit)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.width, initial: true) { _, width in
                            rowWidth = width
                        }
                }
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
        // Above the settings sheet, so `keyOverlay` can name the topmost one.
        .overlay {
            if showShortcuts {
                ShortcutsOverlay(palette: palette, close: { showShortcuts = false })
                    .transition(.opacity)
            }
        }
        // Everything in Shortcuts.all that is not a menu item. The closure is
        // asked at the keystroke, and re-supplied on every update, so no flag it
        // reads can be stale.
        .shortcutKeys(keyContext: keyContext, perform: perform)
        .onReceive(NotificationCenter.default.publisher(for: .mdvOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvPageInputFocus)) { note in
            pageInputFocused = (note.object as? NSNumber)?.boolValue ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: .mdvToggleFrontmatter)) { _ in
            guard doc.url != nil else { return }
            showFrontmatter.toggle()
        }
        .onChange(of: doc.url) { _, _ in
            showFrontmatter = false
            // Belt and braces behind the page's own reporting: opening another
            // document re-renders, and nothing in the page should still be
            // holding the keyboard. The page says so too (window blur, and a
            // report at startup), but a stuck flag kills every plain key, so it
            // is worth clearing from both sides.
            pageInputFocused = false
        }
        // The titlebar is transparent, so content owns the whole window frame.
        .ignoresSafeArea()
        // No focus rings on any control: this is a reading window, and SwiftUI
        // otherwise gives the header button focus at launch and draws a ring
        // around it. Inherited by every descendant.
        .focusEffectDisabled()
        .background(WindowChrome(background: palette.bg))
        // Not cosmetic: this is what makes AppKit draw its own parts — the
        // scrollers in both panels above all — in the theme's tone rather than
        // the OS's. See `themeColorScheme`.
        .preferredColorScheme(themeColorScheme)
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
        .onReceive(NotificationCenter.default.publisher(for: .mdvToggleOutline)) { _ in
            toggleOutline()
        }
        // The panels' slide is declared here, on the view, rather than wrapped
        // around the two toggles in `withAnimation`. Both flags are @AppStorage,
        // and an @AppStorage write is invalidated a beat later than a @State one:
        // by the time SwiftUI acts on it, a transaction opened inside SwiftUI's
        // own dispatch — a button's action, a publisher's delivery — has closed
        // again, and the animation with it. Only the key monitor animated, because
        // it runs outside that cycle. Measured in tools/test-panel-animation.swift.
        //
        // Keyed on the two flags alone: dragging a seam writes `sidebarWidth`
        // continuously, and animating *that* would make the drag lag the pointer.
        .animation(.easeOut(duration: 0.2), value: sidebarVisible)
        .animation(.easeOut(duration: 0.2), value: outlineVisible)
    }

    // A panel is capped by what the window can spare: the other panel, plus the
    // document's minimum. Past that the HStack has to squeeze someone, and the
    // seam jumps around under the pointer mid-drag.
    // Each reads the other's *stored* width, not its clamped one: clamped widths
    // are defined in terms of these limits, and the pair would recurse forever.
    private var sidebarLimit: Double {
        limit(ViewerView.sidebarWidthRange, sharing: outlineVisible ? outlineWidth : 0)
    }

    private var contentsLimit: Double {
        limit(ViewerView.outlineWidthRange, sharing: sidebarVisible ? storedWidth : 0)
    }

    private func limit(_ range: ClosedRange<Double>, sharing other: Double) -> Double {
        guard rowWidth > 0 else { return range.upperBound }
        let spare = rowWidth - other - ViewerView.documentMinWidth
        return min(range.upperBound, max(range.lowerBound, spare))
    }

    /// What each panel is drawn at: the stored width, held to the current limit.
    /// The stored value is left alone, so making the window roomy again restores
    /// the width the reader chose.
    private var sidebarWidth: Double { min(storedWidth, sidebarLimit) }
    private var contentsWidth: Double { min(outlineWidth, contentsLimit) }

    private var palette: Palette {
        (AppTheme(rawValue: themeName) ?? .system).palette(dark: colorScheme == .dark)
    }

    /// Native scrollers take their colour from the window's appearance, not from
    /// our palette, so a light theme under a dark macOS drew a white knob on cream
    /// paper. Pinning the window to the theme's tone fixes the scrollers in both
    /// panels, and everything else AppKit draws for itself.
    ///
    /// System stays nil deliberately: pinning it would freeze the app in whichever
    /// tone it launched in, since `colorScheme` — which is how System resolves —
    /// reads back from this.
    private var themeColorScheme: ColorScheme? {
        switch AppTheme(rawValue: themeName) ?? .system {
        case .system: return nil
        case .night: return .dark
        case .paper, .vellum: return .light
        }
    }

    /// The design shows a word count under the filename.
    ///
    /// The count comes from the page, which is the only side that splits
    /// frontmatter off the body — see DESIGN.md. It therefore arrives one
    /// message after the file is read, and is blank until then.
    private var documentMeta: String {
        guard doc.url != nil else { return "" }
        if let error = doc.loadError { return error }
        guard let words = doc.wordCount else { return "" }
        return words == 1 ? "1 word" : "\(words.formatted()) words"
    }

    // MARK: Keyboard shortcuts

    /// What a keystroke means right now. Built here because this is where the
    /// overlay flags live; `window` comes from the view hierarchy, which is the
    /// one thing a SwiftUI view cannot ask for itself.
    private func keyContext(in window: NSWindow?) -> KeyContext {
        KeyContext(
            windowIsKey: window != nil && window == NSApp.keyWindow,
            editingChromeText: KeyContext.isEditingText(in: window),
            pageInputFocused: pageInputFocused,
            overlay: keyOverlay
        )
    }

    /// The topmost overlay, in the order they are drawn above.
    private var keyOverlay: KeyContext.Overlay {
        if showShortcuts { return .help }
        if showSettings { return .settings }
        if showFrontmatter, doc.url != nil { return .frontMatter }
        return .none
    }

    /// Whatever the monitor resolved. The panels and the overlays are ours; the
    /// rest is the page's, reached the way the menu reaches it.
    ///
    /// Exhaustive on purpose: a new action has to be given a home here, or the
    /// compiler says so.
    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleSidebar: toggleSidebar()
        case .toggleContents: toggleOutline()
        case .toggleShortcutsHelp: showShortcuts.toggle()
        case .dismissOverlay:
            if showShortcuts { showShortcuts = false } else { post(.mdvDismissFind) }
        case .scrollHalfPageDown: post(.mdvScrollHalfPage, 1)
        case .scrollHalfPageUp: post(.mdvScrollHalfPage, -1)
        case .jumpToBottom: post(.mdvScrollToEdge, 1)
        case .jumpToTop: post(.mdvScrollToEdge, -1)
        case .nextHeading: post(.mdvStepHeading, 1)
        case .previousHeading: post(.mdvStepHeading, -1)
        // Guarded the same way the Find… menu item is `.disabled(doc.url == nil)`:
        // with no document there is nothing to search, and the two must agree.
        case .find: if doc.url != nil { post(.mdvFind) }
        // Menu items own their own key equivalents, so `Shortcuts.resolve` never
        // hands these over — see the `.menu` entries in the table.
        case .openFile, .addFolder, .reload, .reloadRenderer, .revealInFinder, .copyDocument,
            .printDocument, .zoomIn, .zoomOut, .zoomReset, .openSettings, .toggleFrontMatter:
            break
        }
    }

    private func post(_ name: Notification.Name, _ direction: Int? = nil) {
        NotificationCenter.default.post(
            name: name, object: direction.map { NSNumber(value: $0) })
    }

    // Plain mutations: the slide is the view's, not the caller's. See the
    // `.animation` modifiers on the body.
    private func toggleOutline() { outlineVisible.toggle() }

    private func toggleSidebar() { sidebarVisible.toggle() }

}

/// A wide-enough grab area sitting on a panel's seam, drawing nothing.
///
/// `edge` is the side of the panel it sits on, which is also the direction a
/// drag has to go to make that panel wider.
struct ResizeHandle: View {
    @Binding var width: Double
    let edge: HorizontalEdge
    let range: ClosedRange<Double>
    @State private var widthAtDragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .contentShape(Rectangle())
            // Straddling the seam: half the grab area sits over the document.
            .offset(x: edge == .trailing ? 4 : -4)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = width }
                        let grown =
                            edge == .trailing
                            ? value.translation.width : -value.translation.width
                        width = min(max(start + grown, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}

/// The 52pt band across the top of the window.
///
/// Split by a hairline at the sidebar's edge: the traffic lights and the sidebar
/// toggle sit left of it, the document's name and word count centred right of
/// it. No filename in the real titlebar — that is hidden, so this is it.
struct TitleBar: View {
    /// Point size of the second row — the word count, and the caret beside it.
    private static let metaSize: CGFloat = 10
    /// Height of that row, taken from the font it is set in rather than guessed
    /// at. The word count arrives from the page one message after the document
    /// opens, so the row is briefly without it — and with the height left to the
    /// content it would grow by 7pt when the count landed, re-centring the
    /// filename above it in the fixed 52pt band.
    static let metaRowHeight = NSLayoutManager().defaultLineHeight(
        for: NSFont(name: Typeface.body, size: metaSize) ?? .systemFont(ofSize: metaSize))

    let name: String?
    let meta: String
    let sidebarWidth: CGFloat
    let sidebarVisible: Bool
    let canCopy: Bool
    let outlineOpen: Bool
    let toggleOutline: () -> Void
    let frontmatter: Frontmatter
    @Binding var showingFrontmatter: Bool
    let palette: Palette
    let toggleSidebar: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            leftZone
            documentLabel
            // A cluster, not a row of touching squares: --space-2 between them,
            // --space-3 to the window edge.
            HStack(spacing: 9.2) {
                if canCopy {
                    CopyButton(palette: palette)
                }
                IconButton(
                    symbol: "list.bullet", palette: palette, active: outlineOpen,
                    action: toggleOutline
                )
                .help("Contents (⌥⌘O)")
                IconButton(symbol: "gearshape", palette: palette, action: openSettings)
                    .help("Settings (⌘,)")
            }
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
                        .font(Typeface.text(TitleBar.metaSize))
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
            .frame(height: TitleBar.metaRowHeight)
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
