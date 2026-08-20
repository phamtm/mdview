import SwiftUI

/// The settings panel from the design: a small window floating over a dimmed,
/// blurred backdrop, with its own titlebar and close dot. Not a native sheet —
/// that brings chrome of its own that fights the palette.
struct SettingsSheet: View {
    @Binding var theme: String
    @Binding var size: String
    /// Which theme is actually in effect, so "Follow System" still shows a
    /// selected swatch rather than none at all.
    let effectiveTheme: String
    let palette: Palette
    let close: () -> Void
    let settingsChanged: () -> Void

    private static let space3: CGFloat = 13.8
    private static let space4: CGFloat = 18.4
    private static let space6: CGFloat = 27.6

    var body: some View {
        ZStack {
            backdrop
            panel
        }
        .onExitCommand(perform: close)
    }

    private var backdrop: some View {
        Color(.sRGB, red: 20 / 255, green: 19 / 255, blue: 18 / 255, opacity: 0.34)
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: close)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            panelTitleBar
            content
            footer
        }
        .frame(width: 520)
        .background(palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.text.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 35, x: 0, y: 30)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Theme")
                .padding(.bottom, Self.space3)
            themeSwatches
                .padding(.bottom, Self.space6)
            typeSize
        }
        .padding(.horizontal, Self.space6)
        .padding(.top, Self.space6)
        .padding(.bottom, Self.space4)
    }

    private var panelTitleBar: some View {
        HStack(spacing: 0) {
            Button(action: close) {
                Circle()
                    .fill(Color(hex: 0xe8_695f))
                    .overlay(Circle().strokeBorder(.black.opacity(0.16), lineWidth: 1))
                    .frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .help("Close")
            .frame(width: 90, alignment: .leading)

            Text("Settings")
                .font(Typeface.display(13))
                .tracking(0.26)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)

            Spacer().frame(width: 90)
        }
        .padding(.horizontal, Self.space4)
        .frame(height: 42)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typeface.display(10))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(palette.muted)
    }

    /// Each theme previews itself as a miniature page: a title bar, a gold rule,
    /// three lines of text.
    private var themeSwatches: some View {
        HStack(spacing: Self.space3) {
            ForEach(SettingsSheet.choices, id: \.id) { choice in
                let selected =
                    theme == choice.id
                    || (theme == AppTheme.system.rawValue && effectiveTheme == choice.id)
                let preview = choice.palette
                VStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: 0.6, height: 6, color: preview.text)
                        Rectangle().fill(preview.accent).frame(height: 1)
                        bar(width: 1.0, height: 3, color: preview.muted)
                        bar(width: 0.9, height: 3, color: preview.muted)
                        bar(width: 0.72, height: 3, color: preview.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .frame(height: 74)
                    .background(preview.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

                    Text(choice.name)
                        .font(Typeface.display(13))
                        .foregroundStyle(selected ? palette.accentText : palette.text)
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            selected ? palette.accent : palette.text.opacity(0.12),
                            lineWidth: selected ? 1.5 : 1
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    theme = choice.id
                    settingsChanged()
                }
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: geo.size.width * width, height: height)
        }
        .frame(height: height)
    }

    private var typeSize: some View {
        HStack(spacing: Self.space4) {
            Text("Type size")
                .font(Typeface.display(14))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(Array(SettingsSheet.sizes.enumerated()), id: \.element.id) {
                    index, option in
                    let selected = size == option.id
                    Text(option.name)
                        .font(Typeface.display(12.5))
                        .foregroundStyle(selected ? palette.text : palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(palette.accent.opacity(selected ? 0.16 : 0))
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle().fill(palette.divider).frame(width: 1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            size = option.id
                            settingsChanged()
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(palette.divider, lineWidth: 1)
            )
        }
        .padding(.top, Self.space3)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Button("Restore defaults") {
                theme = AppTheme.paper.rawValue
                size = "regular"
                settingsChanged()
            }
            .buttonStyle(GhostButtonStyle(palette: palette))

            Spacer()

            Button("Done", action: close)
                .buttonStyle(OutlineButtonStyle(palette: palette))
        }
        .padding(.horizontal, Self.space4)
        .padding(.vertical, Self.space3)
        .background(palette.surface.opacity(0.45))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    // MARK: Options

    private struct Choice {
        let id: String
        let name: String
        let palette: Palette
    }

    private static let choices = [
        Choice(id: AppTheme.paper.rawValue, name: "Paper", palette: .paper),
        Choice(id: AppTheme.vellum.rawValue, name: "Vellum", palette: .vellum),
        Choice(id: AppTheme.night.rawValue, name: "Colophon", palette: .night),
    ]

    private struct SizeOption {
        let id: String
        let name: String
    }

    private static let sizes = [
        SizeOption(id: "small", name: "Small"),
        SizeOption(id: "regular", name: "Regular"),
        SizeOption(id: "large", name: "Large"),
    ]
}

/// Text in the accent, no border — the design's ghost button.
struct GhostButtonStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.display(12.5))
            .foregroundStyle(palette.accentText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.accent.opacity(configuration.isPressed ? 0.18 : 0))
            )
    }
}
