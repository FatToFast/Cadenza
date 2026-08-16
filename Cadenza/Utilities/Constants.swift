import SwiftUI
import UIKit

// MARK: - BPM Ranges

enum BPMRange {
    static let targetMin: Double = 140
    static let targetMax: Double = 220
    static let targetDefault: Double = 180
    static let originalDefault: Double = 120
    static let originalMin: Double = 30
    static let originalMax: Double = 300
    static let rateMin: Float = 0.5
    /// Runner-facing playback must never slow a track below its original speed.
    /// Keep the lower-level AVAudioUnit-supported minimum separate so defensive
    /// clamps do not accidentally re-enable <1.0x playback.
    static let playbackRateMin: Float = 1.0
    static let rateMax: Float = 2.5
    /// MusicKit may briefly quantize or reset playbackRate while a queue entry changes.
    /// Differences inside this band are harmless only when the actual rate is still >= 1.0.
    static let playbackRateTolerance: Float = 0.005
    static let doubleTimeThreshold: Double = 100

    /// Every runner-facing playback path must use the same finite, no-slowdown clamp.
    static func sanitizedPlaybackRate(_ rate: Double) -> Float {
        guard rate.isFinite else { return playbackRateMin }
        return Float(min(max(rate, Double(playbackRateMin)), Double(rateMax)))
    }

    /// A sub-1.0 actual rate is always corrected, even when it is numerically close
    /// to the desired value. This prevents tolerance checks from legitimizing slowdown.
    static func shouldEnforcePlaybackRate(actual: Float, desired: Float) -> Bool {
        guard actual.isFinite else { return true }
        let safeDesired = sanitizedPlaybackRate(Double(desired))
        if actual < playbackRateMin { return true }
        return abs(actual - safeDesired) > playbackRateTolerance
    }

    /// 케이던스 드리프트: 원곡×2^k 후보가 사용자 케이던스에서 이 값(±BPM) 이내면
    /// 원곡 속도(배속 1.0) 재생으로 두고 케이던스를 그 후보로 살짝 이동시킨다.
    static let cadenceDriftTolerance: Double = 10
    /// 기본 폴딩 배속이 이 값을 초과할 때만 드리프트를 고려한다. 이하이면 음질 손실이
    /// 크지 않으므로 사용자가 설정한 케이던스를 그대로 존중한다.
    static let driftRateThreshold: Double = 1.25

    /// 이전 버전에서 90대 BPM으로 저장한 목표값을 러닝 케이던스 범위로 올린다.
    static func normalizedTargetCadence(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return targetDefault }
        let cadence = value < targetMin ? min(value * 2, targetMax) : value
        return min(max(cadence, targetMin), targetMax)
    }

    /// 곡 BPM의 반/두 배 후보 중 러닝 케이던스 범위에 들어오는 값을 반환한다.
    /// 90 BPM과 180 BPM처럼 음악적으로 같은 박자를 UI에서 같은 SPM 체계로 보여준다.
    static func runningCadenceEquivalent(
        forSongBPM bpm: Double,
        near targetCadence: Double = targetDefault
    ) -> Double? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        let candidates = [0.25, 0.5, 1.0, 2.0, 4.0]
            .map { bpm * $0 }
            .filter { $0 >= targetMin && $0 <= targetMax }
        return candidates.min { lhs, rhs in
            abs(lhs - targetCadence) < abs(rhs - targetCadence)
        }
    }

    static func automaticTarget(forOriginalBPM originalBPM: Double) -> Double {
        runningCadenceEquivalent(forSongBPM: originalBPM) ?? targetDefault
    }

    /// targetCadence × 2^k (k: 폴딩 배수) 후보 중 배속이 1.0 이상이면서 가장 1.0에
    /// 가까운(가장 작은) 음악적 목표 BPM을 반환. 원곡보다 느린 재생은 러닝에 부적합
    /// 하므로 배속 < 1.0 후보는 상향 후보가 하나도 없을 때만 폴백으로 허용한다.
    ///
    /// 러닝 케이던스는 전역·스티키 값이고, 곡마다 원곡 템포가 다르므로 배속을
    /// 옥타브 폴딩으로 재계산한다. 예) 원곡 85 + 케이던스 170 → 목표 85 (배속 1.0,
    /// 한 박에 두 걸음). originalBPM <= 0이면 폴딩 근거가 없어 targetCadence를 그대로 반환.
    static func foldedMusicalTarget(targetCadence: Double, originalBPM: Double) -> Double {
        guard originalBPM > 0 else { return targetCadence }
        let multipliers: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

        var bestUp: Double?
        var bestUpRate = Double.infinity
        var nearest = targetCadence
        var nearestDistance = Double.infinity
        for multiplier in multipliers {
            let candidate = targetCadence * multiplier
            let rate = candidate / originalBPM
            guard rate > 0 else { continue }
            if rate >= 1.0, rate < bestUpRate {
                bestUpRate = rate
                bestUp = candidate
            }
            let distance = abs(log2(rate))
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = candidate
            }
        }
        return bestUp ?? nearest
    }

    static func metronomeCadence(forTargetBPM targetBPM: Double) -> Double {
        let cadence = targetBPM < doubleTimeThreshold ? targetBPM * 2 : targetBPM
        return min(max(cadence, targetMin), targetMax)
    }

    /// 재생 배속과 실제 걸음 케이던스를 함께 결정하는 템포 계획.
    /// `musicalTarget`은 재생 배속 계산(musicalTarget/originalBPM)에,
    /// `effectiveCadence`는 메트로놈·UI 표시에 쓰인다.
    struct TempoPlan {
        let musicalTarget: Double
        let effectiveCadence: Double
    }

    /// 원곡 91~95 BPM처럼 케이던스 180에 맞추면 배속이 1.9 근처까지 치솟아 음질이
    /// 크게 나빠지는 곡은, 원곡 속도(배속 1.0)로 두고 케이던스를 원곡×2^k(±tolerance)로
    /// 살짝 이동시키는 편이 낫다. 이 규칙을 "케이던스 드리프트"라 한다.
    ///
    /// - 기본: `foldedMusicalTarget` 결과 = musicalTarget, effectiveCadence = targetCadence.
    /// - 드리프트: 기본 폴딩 배속이 `driftRateThreshold`를 초과하고, 원곡×2^k(k ∈ {0,1,2})
    ///   중 targetCadence와의 차가 `cadenceDriftTolerance` 이내인 값이 있으면
    ///   → musicalTarget = originalBPM (배속 1.0), effectiveCadence = 가장 가까운 그 값.
    /// - originalBPM <= 0이면 폴딩 근거가 없어 (targetCadence, targetCadence) 반환.
    static func tempoPlan(targetCadence: Double, originalBPM: Double) -> TempoPlan {
        guard originalBPM > 0 else {
            return TempoPlan(musicalTarget: targetCadence, effectiveCadence: targetCadence)
        }

        let baseTarget = foldedMusicalTarget(targetCadence: targetCadence, originalBPM: originalBPM)
        let baseRate = baseTarget / originalBPM
        guard baseRate > driftRateThreshold else {
            return TempoPlan(musicalTarget: baseTarget, effectiveCadence: targetCadence)
        }

        var driftCadence: Double?
        var driftDistance = Double.infinity
        for k in 0...2 {
            let candidate = originalBPM * pow(2.0, Double(k))
            let distance = abs(candidate - targetCadence)
            if distance <= cadenceDriftTolerance, distance < driftDistance {
                driftDistance = distance
                driftCadence = candidate
            }
        }

        if let driftCadence {
            return TempoPlan(musicalTarget: originalBPM, effectiveCadence: driftCadence)
        }
        return TempoPlan(musicalTarget: baseTarget, effectiveCadence: targetCadence)
    }
}

enum MetronomeDefaults {
    static let enabled = false
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
