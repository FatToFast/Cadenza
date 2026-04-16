import SwiftUI

// MARK: - BPM Ranges

enum BPMRange {
    static let targetMin: Double = 140
    static let targetMax: Double = 200
    static let targetDefault: Double = 170
    static let originalDefault: Double = 120
    static let originalMin: Double = 30
    static let originalMax: Double = 300
    static let rateMin: Float = 0.5
    static let rateMax: Float = 2.5
}

// MARK: - Colors (DESIGN.md 4.2)

extension Color {
    static let cadenzaBackground = Color(hex: 0x0A0A0F)
    static let cadenzaBackgroundSecondary = Color(hex: 0x1A1A22)
    static let cadenzaAccent = Color(hex: 0x00E5C7)
    static let cadenzaWarning = Color(hex: 0xFF8A3D)
    static let cadenzaTextPrimary = Color(hex: 0xF5F5F7)
    static let cadenzaTextSecondary = Color(hex: 0x9A9AA5)
    static let cadenzaTextTertiary = Color(hex: 0x5A5A65)
    static let cadenzaDivider = Color(hex: 0x2A2A35)

    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Typography (DESIGN.md 4.3)

extension Font {
    /// BPM 큰 숫자 (96pt, SF Pro Rounded Bold)
    static let bpmDisplay = Font.system(size: 96, weight: .bold, design: .rounded)

    /// 화면 제목 (34pt)
    static let cadenzaTitle1 = Font.system(size: 34, weight: .bold)

    /// 섹션 제목 (22pt)
    static let cadenzaTitle2 = Font.system(size: 22, weight: .semibold)

    /// 본문 (17pt)
    static let cadenzaBody = Font.system(size: 17, weight: .regular)

    /// 보조 정보 (13pt)
    static let cadenzaCaption = Font.system(size: 13, weight: .regular)

    /// 숫자 정렬용 모노 (17pt)
    static let cadenzaNumeric = Font.system(size: 17, weight: .regular, design: .monospaced)
}
