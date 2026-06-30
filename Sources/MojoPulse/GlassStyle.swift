import SwiftUI

/// Shared visual vocabulary for the redesigned popover — a restrained take on
/// the macOS 26 ("Tahoe") look: subtle translucent fills (the system
/// `.quaternary` style), continuous "squircle" corners, hairline edges, and
/// hover/press feedback on interactive surfaces. Deliberately native, not a
/// heavy glass effect — no shadows, blur, or glow.

extension View {
    /// Static (non-interactive) card surface: a translucent fill with a
    /// hairline edge and continuous corners. For summary/identity blocks.
    func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

/// Interactive domain-card surface: a translucent fill that lifts on hover and
/// dims on press, with a hairline edge and continuous corners.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.08 : 0.05)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.10 : 0.06))
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Hover/press feedback for the clickable vitals tiles — a faint highlight and
/// hairline on hover, a slight dim on press, layered over the tile's existing
/// fill so the resting look is unchanged. Matches the tile's 12pt corner.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .opacity(configuration.isPressed ? 0.7 : 1.0)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Interactive list-row surface: a subtle full-width highlight on hover/press,
/// no border — for the rows inside the drill-in screens.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.06 : 0)))
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
