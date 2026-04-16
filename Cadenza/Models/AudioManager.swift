import AVFoundation
import Combine
import os

private let logger = Logger(subsystem: "com.cadenza.app", category: "AudioManager")

// MARK: - State Machine (SPEC.md 1.6)

enum PlaybackState: String {
    case idle
    case loading
    case ready
    case playing
    case paused
    case error
}

// MARK: - AudioManager

/// AVAudioEngine 래핑. 앱의 오디오 재생 전체를 관리한다.
///
/// Node graph (SPEC.md 1.6):
///   PlayerNode → TimePitch → MainMixer → Output
///
/// 루핑: completion handler 재스케줄 방식 (Eng Review 결정)
/// 소유: 앱 루트에서 @StateObject로 생성 (Eng Review 결정)
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: PlaybackState = .idle
    @Published var targetBPM: Double = BPMRange.targetDefault {
        didSet { updateRate() }
    }
    @Published private(set) var originalBPM: Double = BPMRange.originalDefault
    @Published private(set) var trackTitle: String?
    @Published private(set) var trackArtist: String?
    @Published private(set) var errorMessage: String?

    var playbackRate: Double {
        guard originalBPM > 0 else { return 1.0 }
        let rate = targetBPM / originalBPM
        return min(max(rate, Double(BPMRange.rateMin)), Double(BPMRange.rateMax))
    }

    var hasBPMFromMetadata: Bool { _bpmFromMetadata }

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var _bpmFromMetadata = false
    private var isScheduling = false

    // MARK: - Init

    init() {
        setupEngine()
    }

    // MARK: - Engine Setup

    /// Attach nodes BEFORE connecting them (SPEC.md 주의사항)
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)

        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        timePitch.pitch = 0 // 피치 유지 (key lock)
    }

    // MARK: - File Loading

    func loadFile(url: URL) async {
        state = .loading
        errorMessage = nil
        trackTitle = nil
        trackArtist = nil
        _bpmFromMetadata = false

        // Security-scoped resource access
        let accessing = url.startAccessingSecurityScopedResource()

        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file

            // 트랙 메타데이터 읽기
            let asset = AVAsset(url: url)
            if let metadata = try? await asset.load(.metadata) {
                trackTitle = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
                    ?? url.deletingPathExtension().lastPathComponent
                trackArtist = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first?.stringValue
            } else {
                trackTitle = url.deletingPathExtension().lastPathComponent
            }

            // BPM 메타데이터 읽기
            if let bpm = await BPMMetadataReader.readBPM(from: url) {
                originalBPM = bpm
                _bpmFromMetadata = true
                logger.info("[track_loaded] BPM from metadata: \(bpm)")
            } else {
                originalBPM = BPMRange.originalDefault
                _bpmFromMetadata = false
                logger.info("[track_loaded] No BPM metadata, using default \(BPMRange.originalDefault)")
            }

            updateRate()
            state = .ready
            logger.info("[track_loaded] \(url.lastPathComponent) loaded successfully")

        } catch {
            state = .error
            errorMessage = "파일을 열 수 없습니다"
            logger.error("[F-01] File load failed: \(error.localizedDescription)")
        }

        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Playback Control

    func play() {
        guard state == .ready || state == .paused else { return }
        guard audioFile != nil else { return }

        do {
            if !engine.isRunning {
                try engine.start()
            }

            if state == .ready {
                scheduleLoop()
            }

            playerNode.play()
            state = .playing
            logger.info("[run_started] targetBPM=\(self.targetBPM) originalBPM=\(self.originalBPM)")

        } catch {
            state = .error
            errorMessage = "오디오 재생을 시작할 수 없습니다"
            logger.error("[A-01] Engine start failed: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard state == .playing else { return }
        playerNode.pause()
        state = .paused
    }

    func togglePlayPause() {
        switch state {
        case .ready, .paused:
            play()
        case .playing:
            pause()
        default:
            break
        }
    }

    // MARK: - Looping (completion handler 재스케줄)

    /// 곡 끝에서 completion handler로 다시 스케줄하여 반복 재생.
    /// completion handler는 private audio thread에서 호출됨 → MainActor로 돌아와야 함.
    private func scheduleLoop() {
        guard let file = audioFile else { return }
        guard !isScheduling else { return }
        isScheduling = true

        // 파일 처음부터 스케줄
        file.framePosition = 0
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .playing else {
                    self?.isScheduling = false
                    return
                }
                self.isScheduling = false
                self.scheduleLoop()
                logger.debug("Loop: re-scheduled from completion handler")
            }
        }
    }

    // MARK: - Rate

    func setOriginalBPM(_ bpm: Double) {
        // SPEC.md 2.8: 30~300 범위만 허용
        guard bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else { return }
        originalBPM = bpm
        _bpmFromMetadata = false
        updateRate()
    }

    private func updateRate() {
        // A-04: division by zero 방어
        guard originalBPM > 0 else {
            originalBPM = BPMRange.originalDefault
            logger.error("[A-04] originalBPM was 0, reset to default \(BPMRange.originalDefault)")
            return
        }
        let rate = Float(playbackRate)
        timePitch.rate = rate
    }
}
