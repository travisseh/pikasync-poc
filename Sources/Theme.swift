import SwiftUI

/// Design tokens — see DESIGN.md (shared with the Android app).
enum Pika {
    static let bg = Color.white
    static let bgSoft = Color(hex: 0xF7F7F7)
    static let ink = Color(hex: 0x222222)
    static let inkSecondary = Color(hex: 0x717171)
    static let hairline = Color(hex: 0xEBEBEB)
    static let accent = Color(hex: 0xFF385C)
    static let accentPress = Color(hex: 0xE31C5F)

    static let cardRadius: CGFloat = 16
    static let sheetRadius: CGFloat = 20
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Reusable modifiers & styles

extension View {
    /// Layered soft shadow per DESIGN.md.
    func pikaShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 24, y: 8)
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }
}

/// Press-down spring scale for photo cards.
struct PressCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Accent pill primary button.
struct PillButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(filled ? .white : Pika.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule().fill(filled
                    ? (configuration.isPressed ? Pika.accentPress : Pika.accent)
                    : Color.white)
            )
            .overlay(filled ? nil : Capsule().stroke(Pika.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Bottom-third gradient scrim for text over photos.
struct Scrim: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0), location: 0.45),
            .init(color: .black.opacity(0.55), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}
