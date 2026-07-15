import SwiftUI
import UIKit

// MARK: - BPM Ranges

enum BPMRange {
    static let targetMin: Double = 140
    static let targetMax: Double = 200
    static let targetDefault: Double = 180
    static let cadenceAllowance: Double = 10
    static let originalDefault: Double = 120
    static let originalMin: Double = 30
    static let originalMax: Double = 300
    static let rateMin: Float = 0.5
    static let rateMax: Float = 2.5

    enum TempoMode: Equatable, Sendable {
        case originalSpeed
        case adjustedSpeed
        case rejected
    }

    enum TempoRejectionReason: Equatable, Sendable {
        case invalidOriginalBPM
    }

    struct TempoPlan: Equatable, Sendable {
        let baseCadence: Double
        let allowedCadence: ClosedRange<Double>
        let musicalTarget: Double
        let effectiveCadence: Double
        let requiredPlaybackRate: Double
        let mode: TempoMode
        let rejectionReason: TempoRejectionReason?

        var isPlayable: Bool { rejectionReason == nil }
        var playbackRate: Double { isPlayable ? requiredPlaybackRate : 1.0 }
    }

    static func tempoPlan(targetCadence: Double, originalBPM: Double) -> TempoPlan {
        let normalizedTarget = targetCadence.isNaN ? targetDefault : targetCadence
        let base = min(max(normalizedTarget, targetMin), targetMax)
        let allowed = base...min(base + cadenceAllowance, targetMax)

        guard originalBPM.isFinite,
              (originalMin...originalMax).contains(originalBPM) else {
            return rejectedPlan(
                base: base,
                allowed: allowed
            )
        }

        let originalSpeedCadences = [0.5, 1.0, 2.0, 4.0].map { originalBPM * $0 }
        if let effectiveCadence = originalSpeedCadences.first(where: allowed.contains) {
            return TempoPlan(
                baseCadence: base,
                allowedCadence: allowed,
                musicalTarget: originalBPM,
                effectiveCadence: effectiveCadence,
                requiredPlaybackRate: 1.0,
                mode: .originalSpeed,
                rejectionReason: nil
            )
        }

        let musicalTarget = foldedMusicalTarget(
            targetCadence: base,
            originalBPM: originalBPM
        )
        let requiredPlaybackRate = musicalTarget / originalBPM

        return TempoPlan(
            baseCadence: base,
            allowedCadence: allowed,
            musicalTarget: musicalTarget,
            effectiveCadence: base,
            requiredPlaybackRate: requiredPlaybackRate,
            mode: .adjustedSpeed,
            rejectionReason: nil
        )
    }

    /// targetCadence × 2^k 후보 중 원곡 BPM 이상인 가장 작은 음악 목표를 반환한다.
    /// `tempoPlan`의 지원 범위에서는 항상 상향 후보가 존재한다. 더 넓은 값으로 직접
    /// 호출되더라도 원곡 BPM으로 폴백하므로 이 함수는 감속 목표를 반환하지 않는다.
    ///
    /// 러닝 케이던스는 전역·스티키 값이고, 곡마다 원곡 템포가 다르므로 배속을
    /// 옥타브 폴딩으로 재계산한다. 예) 원곡 85 + 케이던스 170 → 목표 85 (배속 1.0,
    /// 한 박에 두 걸음). 유효하지 않은 원곡 BPM이면 폴딩 근거가 없어 targetCadence를 반환한다.
    static func foldedMusicalTarget(targetCadence: Double, originalBPM: Double) -> Double {
        guard originalBPM.isFinite, originalBPM > 0 else { return targetCadence }
        let multipliers: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

        return multipliers
            .map { targetCadence * $0 }
            .filter { $0 >= originalBPM }
            .min() ?? originalBPM
    }

    static func metronomeCadence(forTargetBPM targetBPM: Double) -> Double {
        min(max(targetBPM, targetMin), targetMax)
    }

    private static func rejectedPlan(
        base: Double,
        allowed: ClosedRange<Double>
    ) -> TempoPlan {
        TempoPlan(
            baseCadence: base,
            allowedCadence: allowed,
            musicalTarget: base,
            effectiveCadence: base,
            requiredPlaybackRate: 0,
            mode: .rejected,
            rejectionReason: .invalidOriginalBPM
        )
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

private enum CadenzaFontName {
    static let monoRegular = "IBMPlexMono-Regular"
    static let monoMedium = "IBMPlexMono-Medium"
}

private extension Font {
    /// IBM Plex Mono if registered, else system monospaced fallback.
    static func cadenzaMono(size: CGFloat, weight: Font.Weight) -> Font {
        let name = weight == .medium || weight == .semibold || weight == .bold
            ? CadenzaFontName.monoMedium
            : CadenzaFontName.monoRegular

        if UIFont(name: name, size: size) != nil {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}

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
    static let cadenzaMonoValue = Font.cadenzaMono(size: 13, weight: .medium)

    /// 모노 타임코드 (12pt)
    static let cadenzaMonoTimecode = Font.cadenzaMono(size: 12, weight: .regular)

    /// 모노 라벨 (10pt) — TGT/KLK/SPM 등 작은 라벨
    static let cadenzaMonoLabel = Font.cadenzaMono(size: 10, weight: .regular)

    /// 모노 배지 (11pt) — BPM pill 등
    static let cadenzaMonoPill = Font.cadenzaMono(size: 11, weight: .medium)

    /// 숫자 정렬용 모노 (17pt) — 레거시, BPMDisplayView 안 등에서 사용
    static let cadenzaNumeric = Font.cadenzaMono(size: 17, weight: .regular)
}
