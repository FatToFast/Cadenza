import Foundation

/// 곡 끝 도달 시 AudioManager의 동작.
/// - loop: 기존 동작, 같은 파일을 재스케줄.
/// - notify: trackEndedSubject로 이벤트 발행. 재스케줄 없음. 큐 모드.
enum PlaybackEndBehavior: Sendable, Equatable { case loop, notify }
