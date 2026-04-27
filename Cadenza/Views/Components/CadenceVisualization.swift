import SwiftUI

/// 아트워크가 없는 곡을 위한 케이던스 시각화 폴백.
/// - 4겹 동심원 (바깥 → 안쪽 opacity 0.15 → 0.25 → 0.5 → filled)
/// - 중앙 도트 (BPM에 맞춰 미세 발광 펄스)
/// - 좌상단 `CADENCE` 라벨
///
/// Spec: docs/superpowers/specs/2026-04-21-design-system-redesign-design.md §5.2
struct CadenceVisualization: View {
    let bpm: Int
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                Color(hex: 0x0F0F14)

                ringStack(in: size)
                    .frame(width: size, height: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("CADENCE")
                    .font(.cadenzaMonoLabel)
                    .tracking(2)
                    .foregroundColor(.cadenzaTextTertiary)
                    .padding(.leading, 12)
                    .padding(.top, 12)
            }
        }
        .accessibilityLabel("케이던스 \(bpm) BPM 시각화")
    }

    private func ringStack(in size: CGFloat) -> some View {
        let outer = size * 0.86
        return ZStack {
            Circle().stroke(Color.cadenzaAccent.opacity(0.15), lineWidth: outer * 0.012)
                .frame(width: outer, height: outer)
            Circle().stroke(Color.cadenzaAccent.opacity(0.25), lineWidth: outer * 0.014)
                .frame(width: outer * 0.74, height: outer * 0.74)
            Circle().stroke(Color.cadenzaAccent.opacity(0.5), lineWidth: outer * 0.016)
                .frame(width: outer * 0.5, height: outer * 0.5)

            centerDot(diameter: outer * 0.22)
        }
    }

    @ViewBuilder
    private func centerDot(diameter: CGFloat) -> some View {
        if reduceMotion || !isActive || bpm <= 0 {
            Circle()
                .fill(Color.cadenzaAccent)
                .frame(width: diameter, height: diameter)
                .shadow(color: Color.cadenzaAccent.opacity(0.4), radius: 6)
        } else {
            let beatInterval = 60.0 / Double(bpm)
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: beatInterval) / beatInterval
                let scale = 0.95 + 0.10 * sin(.pi * phase)
                let opacity = 0.7 + 0.3 * sin(.pi * phase)
                Circle()
                    .fill(Color.cadenzaAccent.opacity(opacity))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(scale)
                    .shadow(color: Color.cadenzaAccent.opacity(0.4 * opacity), radius: 8)
            }
        }
    }
}
