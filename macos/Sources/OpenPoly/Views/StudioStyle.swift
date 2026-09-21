import SwiftUI

enum Studio {
    static let background = Color(red: 0.055, green: 0.062, blue: 0.069)
    static let sidebar = Color(red: 0.070, green: 0.079, blue: 0.085)
    static let surface = Color(red: 0.094, green: 0.105, blue: 0.113)
    static let raised = Color(red: 0.13, green: 0.145, blue: 0.15)
    static let accent = Color(red: 0.76, green: 0.94, blue: 0.65)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.60)
    static let line = Color.white.opacity(0.07)
}

struct StudioCard<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Studio.accent)
                    .frame(width: 36, height: 36)
                    .background(Studio.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Studio.line))
    }
}

struct StudioButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 17)
            .frame(height: 36)
            .foregroundStyle(primary ? Studio.background : Color.white.opacity(0.85))
            .background(primary ? Studio.accent : Studio.raised, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Capsule())
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .foregroundStyle(Studio.muted)
    }
}
