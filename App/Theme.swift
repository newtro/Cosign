import AppKit
import SwiftUI

// MARK: - Studio Visual Design System ("Obsidian & Warm Brass Council")

enum StudioTheme {
    // Deep layered obsidian surfaces
    static let canvasTop = Color(hex: "#0A0D14")
    static let canvasBottom = Color(hex: "#0E131F")
    static let sidebarBg = Color(hex: "#080A10")
    static let cardSurface = Color(hex: "#121724")
    static let cardElevated = Color(hex: "#171E2E")
    static let drawerBg = Color(hex: "#0B0E17")
    static let dockGlass = Color(hex: "#131927")

    // Brand & Semantic Accents
    static let brass = Color(hex: "#F59E0B")
    static let brassBright = Color(hex: "#FBBF24")
    static let emerald = Color(hex: "#34D399")
    static let crimson = Color(hex: "#F43F5E")
    static let sky = Color(hex: "#60A5FA")

    // Typography hierarchy
    static let inkPrimary = Color(hex: "#F3F5FA")
    static let inkSecondary = Color(hex: "#A5B0C5")
    static let inkMuted = Color(hex: "#68738A")

    // Curated Persona Swatches
    static let personaSwatches: [String] = [
        "#F59E0B", "#34D399", "#F43F5E", "#60A5FA",
        "#C084FC", "#FB923C", "#2DD4BF", "#E879F9",
        "#A3E635", "#38BDF8"
    ]

    // Curated Persona Symbols
    static let personaSymbols: [String] = [
        "crown.fill", "hammer.fill", "flame.fill", "sparkles",
        "paintbrush.pointed.fill", "chart.line.uptrend.xyaxis", "bolt.shield.fill", "brain.head.profile",
        "compass.drawing", "scale.3d", "lightbulb.max.fill", "eyeglasses"
    ]
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b, a) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 255)
        case 8:
            (r, g, b, a) = ((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        default:
            (r, g, b, a) = (96, 165, 250, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

// MARK: - Milled Glass Card Modifier

struct StudioCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var fill: Color = StudioTheme.cardSurface
    var glowColor: Color? = nil
    var glowIntensity: Double = 0.0

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(
                        color: (glowColor ?? .black).opacity(glowColor != nil ? glowIntensity : 0.38),
                        radius: glowColor != nil ? 18 : 14,
                        x: 0,
                        y: glowColor != nil ? 0 : 8
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (glowColor ?? .white).opacity(glowColor != nil ? 0.65 : 0.13),
                                Color.white.opacity(0.05),
                                (glowColor ?? .white).opacity(glowColor != nil ? 0.25 : 0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: glowColor != nil ? 1.35 : 1.0
                    )
            )
    }
}

extension View {
    func studioCard(
        cornerRadius: CGFloat = 16,
        fill: Color = StudioTheme.cardSurface,
        glowColor: Color? = nil,
        glowIntensity: Double = 0.28
    ) -> some View {
        modifier(StudioCardModifier(
            cornerRadius: cornerRadius,
            fill: fill,
            glowColor: glowColor,
            glowIntensity: glowIntensity
        ))
    }
}

// MARK: - Tactile Button Styles

struct StudioPillButtonStyle: ButtonStyle {
    var tint: Color = StudioTheme.inkSecondary
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? tint : StudioTheme.inkSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? tint.opacity(0.16) : Color.white.opacity(configuration.isPressed ? 0.09 : 0.045))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BrassPrimaryButtonStyle: ButtonStyle {
    var accent: Color = StudioTheme.brass

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: "#090B10"))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.95), StudioTheme.brassBright],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: accent.opacity(0.35), radius: 10, x: 0, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Wrapping Flow Layout (Chips & Seals)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 640
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for view in subviews {
            let rawSize = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let itemWidth = min(rawSize.width, maxWidth)
            if x > 0 && x + itemWidth > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + itemWidth)
            rowHeight = max(rowHeight, rawSize.height)
            x += itemWidth + spacing
        }
        return CGSize(width: min(usedWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = max(1, bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let rawSize = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let itemWidth = min(rawSize.width, maxWidth)
            if x > bounds.minX && x + itemWidth > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: itemWidth, height: rawSize.height)
            )
            rowHeight = max(rowHeight, rawSize.height)
            x += itemWidth + spacing
        }
    }
}

// MARK: - Animated Voice Equalizer & Orbiting Thinker Ring

struct LiveEqualizerBars: View {
    var level: CGFloat
    var color: Color
    var barCount: Int = 5
    var maxHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { idx in
                    let wave = CGFloat((sin(t * 9.5 + Double(idx) * 1.35) + 1.0) * 0.5)
                    let activeLevel = max(0.18, min(1.0, level * (0.55 + wave * 0.65)))
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 2.8, height: max(3, maxHeight * activeLevel))
                }
            }
            .frame(height: maxHeight)
        }
    }
}

struct OrbitingThinkingRing: View {
    var color: Color
    var size: CGFloat = 46

    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        color.opacity(0.05),
                        color.opacity(0.35),
                        color,
                        Color.white.opacity(0.9),
                        color.opacity(0.05)
                    ]),
                    center: .center
                ),
                lineWidth: 2.2
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
