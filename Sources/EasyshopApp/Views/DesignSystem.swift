import AppKit
import SwiftUI

/// A small, explicit palette keeps controls readable independently of the
/// system appearance. Easyshop is a dark editing room; controls are the light.
enum EasyshopTheme {
    static let background = Color(red: 0.012, green: 0.016, blue: 0.027)
    static let canvas = Color(red: 0.021, green: 0.026, blue: 0.041)
    static let panel = Color(red: 0.052, green: 0.062, blue: 0.092)
    static let panelRaised = Color(red: 0.086, green: 0.099, blue: 0.145)
    static let line = Color.white.opacity(0.15)
    static let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.39, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.38, blue: 0.78)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.34)
    static let lime = Color(red: 0.58, green: 1.0, blue: 0.72)
    static let ink = Color.white.opacity(0.96)
    static let secondaryInk = Color.white.opacity(0.74)
    static let muted = Color.white.opacity(0.62)

    static let gradient = LinearGradient(
        colors: [cyan, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let aurora = AngularGradient(
        colors: [cyan, violet, pink, cyan],
        center: .center
    )
    static let ambient = RadialGradient(
        colors: [violet.opacity(0.15), cyan.opacity(0.04), .clear],
        center: .center,
        startRadius: 0,
        endRadius: 440
    )
}

/// Liquid glass without a stack of expensive, full-screen blur passes.
/// Material is clipped once and the specular edge supplies the depth.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    var elevated = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(EasyshopTheme.ink)
            .background(.thinMaterial, in: shape)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.105),
                        EasyshopTheme.panel.opacity(0.88),
                        EasyshopTheme.violet.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: shape
            )
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), EasyshopTheme.cyan.opacity(0.12), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(elevated ? 0.40 : 0.22), radius: elevated ? 20 : 9, y: elevated ? 10 : 4)
    }
}

struct FloatingCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(EasyshopTheme.ink)
            .background(.thinMaterial, in: Capsule())
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.11), EasyshopTheme.panel.opacity(0.92), EasyshopTheme.violet.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), EasyshopTheme.cyan.opacity(0.12), Color.white.opacity(0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.36), radius: 18, y: 9)
    }
}

extension View {
    func glassPanel(radius: CGFloat = 16, elevated: Bool = true) -> some View {
        modifier(GlassPanel(radius: radius, elevated: elevated))
    }

    func floatingCapsule() -> some View {
        modifier(FloatingCapsule())
    }
}

/// SF Symbols occasionally differ between macOS releases. Resolving the
/// symbol at runtime prevents a missing glyph from turning a tool into an
/// apparently empty button.
struct SafeSymbol: View {
    let name: String
    var fallback: String = "circle.fill"

    private var resolvedName: String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? fallback : name
    }

    var body: some View {
        Image(systemName: resolvedName)
            .symbolRenderingMode(.monochrome)
            .accessibilityHidden(true)
    }
}

/// Shared icon control. A visible resting surface and explicit monochrome
/// symbol avoid the "empty circles" seen when macOS resolves semantic colors
/// against a light vibrancy context.
struct SymbolButton: View {
    var symbol: String
    var help: String
    var active = false
    var action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            SafeSymbol(name: symbol, fallback: "circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(active ? Color.white : (hovered ? EasyshopTheme.cyan : EasyshopTheme.ink))
                .frame(width: 36, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(active ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.white.opacity(hovered ? 0.13 : 0.075)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(active ? Color.white.opacity(0.30) : Color.white.opacity(hovered ? 0.24 : 0.10), lineWidth: 1)
                }
                .shadow(color: active ? EasyshopTheme.cyan.opacity(0.28) : .clear, radius: 9)
                .scaleEffect(hovered && !reduceMotion ? 1.045 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) { hovered = inside }
        }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(EasyshopTheme.gradient, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.34), lineWidth: 1))
            .shadow(color: EasyshopTheme.cyan.opacity(configuration.isPressed ? 0.06 : 0.22), radius: 11)
            .foregroundStyle(Color.white)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.085), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14)))
            .foregroundStyle(EasyshopTheme.ink)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}
