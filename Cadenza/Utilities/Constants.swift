import SwiftUI

// MARK: - BPM Ranges

enum BPMRange {
    static let targetMin: Double = 90
    static let targetMax: Double = 220
    static let targetDefault: Double = 180
    static let originalDefault: Double = 120
    static let originalMin: Double = 30
    static let originalMax: Double = 300
    static let rateMin: Float = 0.5
    static let rateMax: Float = 2.5
    static let doubleTimeThreshold: Double = 100

    static func automaticTarget(forOriginalBPM originalBPM: Double) -> Double {
        originalBPM < doubleTimeThreshold ? 90 : 180
    }

    static func metronomeCadence(forTargetBPM targetBPM: Double) -> Double {
        let cadence = targetBPM < doubleTimeThreshold ? targetBPM * 2 : targetBPM
        return min(max(cadence, targetMin), targetMax)
    }
}

enum MetronomeDefaults {
    static let enabled = true
    static let volume: Float = 0.6
    static let beatsPerBar = 4
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

// MARK: - Typography (DESIGN.md 4.3, runner-first redesign 2026-04-23)

extension Font {
    /// BPM 디스플레이 (56pt, runner-first에서 96pt → 56pt로 축소)
    static let bpmDisplay = Font.system(size: 56, weight: .bold, design: .rounded)

    /// 화면 제목 (28pt)
    static let cadenzaTitle1 = Font.system(size: 28, weight: .bold)

    /// 섹션 제목 (20pt)
    static let cadenzaTitle2 = Font.system(size: 20, weight: .semibold)

    /// 곡 제목 (26pt, 플레이어 메인)
    static let cadenzaTrackTitle = Font.system(size: 26, weight: .heavy)

    /// 본문 (16pt)
    static let cadenzaBody = Font.system(size: 16, weight: .regular)

    /// 보조 정보 (13pt)
    static let cadenzaCaption = Font.system(size: 13, weight: .regular)

    /// 모노 상태값 (13pt) — BPM·재생률·ON/OFF 등 상태 숫자
    /// IBM Plex Mono 번들 후 `Font.custom("IBMPlexMono-Medium", size: 13)`로 교체 예정
    static let cadenzaMonoValue = Font.system(size: 13, weight: .medium, design: .monospaced)

    /// 모노 타임코드 (12pt)
    static let cadenzaMonoTimecode = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// 모노 라벨 (10pt) — TGT/KLK/SPM 등 작은 라벨
    static let cadenzaMonoLabel = Font.system(size: 10, weight: .regular, design: .monospaced)

    /// 모노 배지 (11pt) — BPM pill 등
    static let cadenzaMonoPill = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// 숫자 정렬용 모노 (17pt) — 레거시, BPMDisplayView 안 등에서 사용
    static let cadenzaNumeric = Font.system(size: 17, weight: .regular, design: .monospaced)
}
