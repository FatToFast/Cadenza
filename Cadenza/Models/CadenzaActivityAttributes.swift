import ActivityKit
import Foundation

/// Live Activity 데이터 컨트랙트 — main app과 Widget Extension이 공유.
struct CadenzaActivityAttributes: ActivityAttributes {
    public typealias ContentState = CadenzaActivityState

    /// 현재는 정적 속성 없음 — 모든 정보가 ContentState에 들어간다.
    /// Activity 생성 시 한 번만 정해지는 값이 생기면 이쪽에 추가.
}

struct CadenzaActivityState: Codable, Hashable {
    var title: String
    var artist: String?
    /// 현재 곡과 재생속도를 반영한 실제 발걸음 케이던스(SPM).
    var effectiveCadence: Int
    /// 사용자가 조절하는 허용 구간의 하한 케이던스(SPM).
    var baseCadence: Int
    /// 분석·메타데이터에서 얻은 원곡 템포(BPM). 0은 아직 확인되지 않았다는 뜻이며,
    /// 케이던스와 섞어 표시하지 않는다.
    var originalBPM: Int
    var elapsed: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    /// `MPMediaItemArtwork`을 직접 보낼 수 없으므로 PNG/JPEG raw bytes로 전달.
    /// 64pt 정사각으로 미리 다운샘플해서 페이로드 크기를 제한할 것.
    var artworkData: Data?
}
