import AppKit
import SwiftUI

/// Quick Open (⌘P): type a few letters, land on the file.
///
/// The fastest way between two documents in a library is not the sidebar tree,
/// which asks the reader to remember where things live; it is the thing every
/// editor taught them: fuzzy-match over everything, ranked, keyboard-driven.
/// Files come from `WorkspaceModel.allFiles()`, which reads folders that have
/// never been expanded, so nothing is missing just because the sidebar is
/// collapsed. An empty query lists the recents, which is usually the answer.
struct QuickOpenPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    let palette: Palette
    let close: () -> Void

    @State private var query = ""
    @State private var results: [FileNode] = []
    @State private var selection = 0
    /// Built once per presentation; a library does not change mid-keystroke.
    @State private var files: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenField(
                query: $query, palette: palette, onChange: { filter() },
                onMove: moveSelection, onConfirm: confirm, onCancel: close,
                onReveal: revealSelected
            )
            .frame(height: 18)
            .padding(.horizontal, 13.8)
            .padding(.vertical, 11)
            .overlay(alignment: .leading) {
                if query.isEmpty {
                    Text("Find a file by name")
                        .font(Typeface.text(13))
                        .foregroundStyle(palette.muted.opacity(0.7))
                        .padding(.leading, 13.8)
                        .allowsHitTesting(false)
                }
            }

            if !results.isEmpty {
                Divider().overlay(palette.divider)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                                // A Button, deliberately, not a tap gesture:
                                // inside a ScrollView the pan recognizer wins
                                // ties on macOS and taps land dead.
                                Button {
                                    selection = index
                                    confirm()
                                } label: {
                                    row(node, selected: index == selection)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { _, newValue in
                        proxy.scrollTo(newValue, anchor: nil)
                    }
                    .frame(maxHeight: 324)
                }
            } else if workspace.roots.isEmpty {
                // An empty library is not an error and must not be silence.
                VStack(spacing: 4) {
                    Text("No folders yet")
                        .font(Typeface.displayMatching(14))
                        .foregroundStyle(palette.text.opacity(0.8))
                    Text("⇧⌘O adds one to the sidebar")
                        .font(Typeface.text(11.5))
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else if !query.isEmpty {
                Text("No file matches")
                    .font(Typeface.displayMatching(13))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.bg)
                .shadow(color: palette.text.opacity(0.22), radius: 22, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.divider, lineWidth: 1)
                )
        )
        .frame(width: 540)
        .onAppear(perform: loadLibrary)
        .onExitCommand(perform: close)
    }

    // MARK: Data

    private func loadLibrary() {
        files = workspace.allFiles()
        filter()
    }
    /// Recents when there is nothing typed; fuzzy matches, best first, after.
    /// Ranked results are capped — a reader narrows the query rather than
    /// scrolling a list of two hundred.
    private func filter() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty {
            let recentPaths = Set(doc.recents.map(\.path))
            let alive = doc.recents.filter { FileManager.default.fileExists(atPath: $0.path) }
            var ordered: [FileNode] = []
            for url in alive {
                if let node = files.first(where: { $0.url.path == url.path }) {
                    ordered.append(node)
                }
            }
            let rest =
                files
                .filter { !recentPaths.contains($0.url.path) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            results = Array((ordered + rest).prefix(9))
            selection = 0
            return
        }

        var scored: [(Int, FileNode)] = []
        for node in files {
            let folder = node.url.deletingLastPathComponent().lastPathComponent
            if let points = score(query: needle, name: node.name, folder: folder),
                points > 0
            {
                scored.append((points, node))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.name.localizedStandardCompare(rhs.1.name) == .orderedAscending
        }
        results = scored.prefix(12).map(\.1)
        selection = 0
    }

    /**
     * Ranks one file against the query: every whitespace-separated term must
     * land in the file's *name*, falling back to its immediate folder only for
     * terms the name does not carry.
     *
     * The first version matched scattered letters across the absolute path,
     * and `/Users/minh/…` carried enough vowels that almost nothing was ruled
     * out — typing a filename barely narrowed the list. Matching now starts
     * from what the reader actually types (the file's name), with the folder
     * as the secondary signal, so `notes api` still finds notes/api.md while
     * `readme` can no longer match half the library through its home prefix.
     */
    private func score(query: String, name: String, folder: String) -> Int? {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return nil }

        var total = 0
        for term in terms {
            let lowered = Array(term.lowercased())
            if let inName = subsequenceScore(lowered, in: name.lowercased()) {
                total += inName * 10
                continue
            }
            // A folder hit narrows the field but must never outrank a file
            // whose own name matched.
            guard let inFolder = subsequenceScore(lowered, in: folder.lowercased()) else {
                return nil
            }
            total += inFolder * 3
        }
        // Shorter names win ties.
        return total - name.count / 4
    }

    /**
     * How well `needle` fits into `haystack` as an unordered-in-advance
     * subsequence: every letter in order, nothing required between them.
     *
     * Contiguous runs beat scattered letters (a growing bonus per letter in
     * the run), letters after a separator or at the front beat word middles,
     * and anything short of a full subsequence returns nil — no match.
     */
    private func subsequenceScore(_ needle: [Character], in haystack: String) -> Int? {
        let hay = Array(haystack)
        var total = 0
        var searchFrom = 0
        var runBonus = 0
        for character in needle {
            // firstIndex on the slice reports absolute positions — slices keep
            // their parent's indices.
            guard let at = hay[searchFrom...].firstIndex(of: character) else { return nil }
            var gained = 1
            if at == searchFrom, total > 0 {
                gained += 4  // contiguous with the previous letter
                runBonus += 2
                gained += runBonus
            } else {
                runBonus = 0
            }
            if at == 0 || " ._-".contains(hay[at - 1]) {
                gained += 3  // a word start
            }
            total += gained
            searchFrom = at + 1
        }
        return total
    }
    // MARK: Keys

    /// Wraps at both ends, like every palette people already use: one past the
    /// last result is the first again.
    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func confirm() {
        guard results.indices.contains(selection) else { return }
        let target = results[selection].url
        close()
        doc.open(target)
    }

    /// ⌘Enter: where the file lives, without opening it here.
    private func revealSelected() {
        guard results.indices.contains(selection) else { return }
        let target = results[selection].url
        close()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: One row

    private func row(_ node: FileNode, selected: Bool) -> some View {
        let folder = node.url.deletingLastPathComponent().path
        return HStack(spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? palette.accentText : palette.muted.opacity(0.8))
                .frame(width: 14)
            Text(node.name)
                .font(Typeface.text(13))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            // The path is provenance, not the result — quieter and smaller
            // than the name, so the eye lands on what was typed for.
            Text(folder)
                .font(Typeface.displayMatching(10.5))
                .foregroundStyle(palette.muted.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 13.8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.accent.opacity(0.16))
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The query field, with the four keys the palette lives by.
///
/// This is an NSTextView, not an NSTextField, and that is two rounds of
/// education. An NSTextField's keys are taken by the window's field editor
/// (an NSTextView), so a keyDown override on the field never runs; moving
/// handling to `control:textView:doCommandBy:` caught Return but not the
/// arrows, because NSTextView implements moveUp:/moveDown: itself and never
/// asks the delegate about commands it owns.
///
/// So the palette brings its own editor. A one-line NSTextView *is* the first
/// responder, its keyDown runs first, and every key means exactly what this
/// panel says it means. The placeholder is drawn in SwiftUI behind it, since
/// a bare text view has none.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var query: String
    let palette: Palette
    let onChange: () -> Void
    let onMove: (Int) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onReveal: () -> Void

    func makeNSView(context: Context) -> QuickOpenTextView {
        let view = QuickOpenTextView()
        // One line of plain text: no rich editing, no font panel, no scrolling,
        // width tracking SwiftUI's frame.
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.font = NSFont(name: Typeface.body, size: 15) ?? .systemFont(ofSize: 15)
        view.onMove = onMove
        view.onConfirm = onConfirm
        view.onCancel = onCancel
        view.onReveal = onReveal
        // A bare text view has no name of its own; VoiceOver needs one.
        view.setAccessibilityLabel("Find a file by name")
        view.delegate = context.coordinator
        // Focus on arrival: the palette exists to be typed into.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: QuickOpenTextView, context: Context) {
        // The closures are re-taken each pass so nothing reads a stale flag.
        view.onMove = onMove
        view.onConfirm = onConfirm
        view.onCancel = onCancel
        view.onReveal = onReveal
        if view.string != query { view.string = query }
        let colour = NSColor(palette.text)
        if view.textColor != colour { view.textColor = colour }
        if view.insertionPointColor != colour { view.insertionPointColor = colour }
    }

    func makeCoordinator() -> Coordinator { Coordinator(query: $query, onChange: onChange) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let query: Binding<String>
        private let onChange: () -> Void

        init(query: Binding<String>, onChange: @escaping () -> Void) {
            self.query = query
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? QuickOpenTextView else { return }
            // Pasted text can carry newlines; this is a one-line field.
            if view.string.contains(where: \.isNewline) {
                view.string = view.string.replacingOccurrences(of: "\n", with: "")
            }
            query.wrappedValue = view.string
            onChange()
        }
    }
}

final class QuickOpenTextView: NSTextView {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onReveal: (() -> Void)?

    /// We are the first responder here — no field editor in between — so this
    /// runs for every key and the palette's four mean what they say.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow:
            onMove?(-1)
            return
        case .downArrow:
            onMove?(1)
            return
        default:
            break
        }
        // ⌘Enter reveals the selection in Finder instead of opening it.
        if event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers == "\r"
                || event.charactersIgnoringModifiers == "\u{3}"
        {
            onReveal?()
            return
        }
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}":
            onConfirm?()
            return
        case "\u{1b}":
            onCancel?()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Belt and braces for a command that arrived outside keyDown (an IME, a
    /// menu): whatever happens, a newline must not enter a one-line field.
    override func insertNewline(_ sender: Any?) {
        onConfirm?()
    }
}
