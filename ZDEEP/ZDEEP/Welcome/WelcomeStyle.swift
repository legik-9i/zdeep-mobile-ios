import SwiftUI

enum WelcomeStyle {
    static let background = Color(hex: 0xF5F5F7)
    static let text = Color(hex: 0x1D1D1F)
    static let secondary = Color(hex: 0x5D5F5F)
    static let white = Color.white
    static let mutedText = text.opacity(0.7)

    static let pageHorizontalInset: CGFloat = 16
    static let pageBottomInset: CGFloat = 32
    static let heroCornerRadius: CGFloat = 24
    static let buttonCornerRadius: CGFloat = 16
    static let buttonVerticalPadding: CGFloat = 16
    static let buttonHorizontalPadding: CGFloat = 24
    static let buttonGap: CGFloat = 12
    static let sectionGap: CGFloat = 40

    static func font(_ face: InterFace, size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(face.postScriptName, size: size, relativeTo: style)
    }

    enum InterFace {
        case regular
        case medium
        case semibold
        case bold

        var postScriptName: String {
            switch self {
            case .regular: "Inter-Regular"
            case .medium: "Inter-Medium"
            case .semibold: "Inter-SemiBold"
            case .bold: "Inter-Bold"
            }
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
