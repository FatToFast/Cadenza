import XCTest
import Combine
import SwiftUI
import UIKit
@testable import Cadenza

@MainActor
final class AudioManagerGenerationTests: XCTestCase {
    func testAudioPreferencesPersistAcrossManagerInstances() {
        let suiteName = "AudioManagerPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AudioManager(defaults: defaults)
        first.targetBPM = 175
        first.metronomeEnabled = false
        first.metronomeVolume = 0.35

        let second = AudioManager(defaults: defaults)

        XCTAssertEqual(second.targetBPM, 175)
        XCTAssertFalse(second.metronomeEnabled)
        XCTAssertEqual(second.metronomeVolume, 0.35, accuracy: 0.001)
    }

    func testMissingAudioPreferencesUseDefaults() {
        let suiteName = "AudioManagerPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let audio = AudioManager(defaults: defaults)

        XCTAssertEqual(audio.targetBPM, BPMRange.targetDefault)
        XCTAssertEqual(audio.metronomeEnabled, MetronomeDefaults.enabled)
        XCTAssertEqual(audio.metronomeVolume, MetronomeDefaults.volume, accuracy: 0.001)
    }

    func testInvalidStoredAudioPreferencesAreNormalized() {
        let suiteName = "AudioManagerPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(130.0, forKey: AudioManager.targetCadenceDefaultsKey)
        defaults.set(2.0, forKey: AudioManager.metronomeVolumeDefaultsKey)
        var audio = AudioManager(defaults: defaults)
        XCTAssertEqual(audio.targetBPM, BPMRange.targetMin)
        XCTAssertEqual(audio.metronomeVolume, 1, accuracy: 0.001)

        defaults.set(230.0, forKey: AudioManager.targetCadenceDefaultsKey)
        defaults.set(-0.5, forKey: AudioManager.metronomeVolumeDefaultsKey)
        audio = AudioManager(defaults: defaults)
        XCTAssertEqual(audio.targetBPM, BPMRange.targetMax)
        XCTAssertEqual(audio.metronomeVolume, 0, accuracy: 0.001)

        defaults.set(Double.nan, forKey: AudioManager.targetCadenceDefaultsKey)
        defaults.set(Double.nan, forKey: AudioManager.metronomeVolumeDefaultsKey)
        audio = AudioManager(defaults: defaults)
        XCTAssertEqual(audio.targetBPM, BPMRange.targetDefault)
        XCTAssertEqual(audio.metronomeVolume, MetronomeDefaults.volume, accuracy: 0.001)

        defaults.set(Double.greatestFiniteMagnitude, forKey: AudioManager.metronomeVolumeDefaultsKey)
        audio = AudioManager(defaults: defaults)
        XCTAssertEqual(audio.metronomeVolume, 1, accuracy: 0.001)
    }

    func testInvalidAssignedAudioPreferencesAreNormalizedAndPersisted() {
        let suiteName = "AudioManagerPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AudioManager(defaults: defaults)
        first.targetBPM = 130
        first.metronomeVolume = 1.5
        XCTAssertEqual(first.targetBPM, BPMRange.targetMin)
        XCTAssertEqual(first.metronomeVolume, 1, accuracy: 0.001)

        first.targetBPM = .nan
        first.metronomeVolume = .nan
        XCTAssertEqual(first.targetBPM, BPMRange.targetDefault)
        XCTAssertEqual(first.metronomeVolume, MetronomeDefaults.volume, accuracy: 0.001)

        let second = AudioManager(defaults: defaults)
        XCTAssertEqual(second.targetBPM, BPMRange.targetDefault)
        XCTAssertEqual(second.metronomeVolume, MetronomeDefaults.volume, accuracy: 0.001)
    }

    func testPlayerViewDoesNotSnapDetectedOriginalBPMToCadenceOctave() async {
        let audio = AudioManager()
        audio.targetBPM = 180
        let host = UIHostingController(rootView: PlayerView().environmentObject(audio))
        host.loadViewIfNeeded()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        host.view.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        audio.setStreamingBeatAlignment(
            bpm: 87,
            source: .analysis,
            beatOffsetSeconds: nil
        )
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(audio.originalBPM, 87)
        XCTAssertEqual(audio.originalBPMSource, .analysis)

        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        await Task.yield()
    }

    func testDefaultBehaviorIsLoop() {
        XCTAssertEqual(AudioManager().playbackEndBehavior, .loop)
    }
    func testBehaviorMutable() {
        let a = AudioManager()
        a.playbackEndBehavior = .notify
        XCTAssertEqual(a.playbackEndBehavior, .notify)
    }
    func testTrackEndedSubjectEmits() {
        let a = AudioManager()
        var n = 0
        let c = a.trackEndedSubject.sink { n += 1 }
        a.trackEndedSubject.send(())
        XCTAssertEqual(n, 1)
        c.cancel()
    }
    func testDefaultNowPlayingEmpty() {
        let info = AudioManager().currentNowPlayingInfo
        XCTAssertNil(info.title)
        XCTAssertEqual(info.originalBPM, BPMRange.originalDefault)
        XCTAssertNil(info.queueContext)
    }

    func testStreamingBeatAlignmentForNinetyBPMKeepsPlaybackRateNearOne() {
        let audio = AudioManager()
        // 케이던스를 명시적으로 고정해 UserDefaults 영속값에 의존하지 않게 한다.
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 89.96,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        // 케이던스는 스티키 — 곡 BPM 도착에도 바뀌지 않는다.
        XCTAssertEqual(audio.targetBPM, 180)
        // 원곡 89.96에 옥타브 폴딩 → 음악 목표 90 → 배속 ≈ 1.0.
        XCTAssertEqual(audio.musicalTargetBPM, 90, accuracy: 0.0001)
        XCTAssertEqual(audio.playbackRate, 90 / 89.96, accuracy: 0.0001)
    }

    func testConfirmedNinetyFiveBPMUsesNativeOneNinetyCadence() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 95,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.tempoPlan.effectiveCadence, 190)
        XCTAssertEqual(audio.playbackRate, audio.tempoPlan.playbackRate, accuracy: 0.0001)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(audio.metronomeBPM, 190)
        XCTAssertTrue(audio.isCurrentTempoPlayable)
    }

    func testConfirmedOneTwentyBPMRejectsUnsafePlaybackRate() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertFalse(audio.tempoPlan.isPlayable)
        XCTAssertLessThan(audio.tempoPlan.requiredPlaybackRate, BPMRange.minimumQualityRate)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(audio.tempoRejectionMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testConfirmedEightyNineBPMAdjustsToBaseCadence() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 89,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertTrue(audio.isCurrentTempoPlayable)
        XCTAssertEqual(audio.tempoPlan.effectiveCadence, 180)
        XCTAssertEqual(audio.playbackRate, 90.0 / 89.0, accuracy: 0.0001)
        XCTAssertEqual(audio.metronomeBPM, 180)
    }

    func testAssumedDefaultBPMNeverAppliesTempoTransform() {
        let audio = AudioManager()
        audio.targetBPM = 180

        XCTAssertEqual(audio.originalBPMSource, .assumedDefault)
        XCTAssertLessThan(audio.tempoPlan.requiredPlaybackRate, BPMRange.minimumQualityRate)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertNil(audio.tempoRejectionMessage)
    }

    func testMetronomeOnlyModeCanStartWithoutPlayableTrackTempo() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.metronomeEnabled = true

        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertFalse(audio.hasLoadedTrack)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertTrue(audio.canStartPlayback)
    }

    func testConfirmedRejectedLocalTrackCannotStartPlayback() async {
        let audio = AudioManager()
        audio.targetBPM = 180

        await audio.loadSampleTrack(.clickLoop)

        XCTAssertEqual(audio.state, .ready)
        XCTAssertTrue(audio.hasLoadedTrack)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertFalse(audio.canStartPlayback)
        XCTAssertEqual(audio.errorMessage, "케이던스 범위에 맞지 않는 곡입니다")

        audio.play()

        XCTAssertEqual(audio.state, .ready)
    }

    func testPlayingDirectLocalTrackPausesAndShowsErrorWhenManualBPMBecomesRejected() async {
        let suiteName = "AudioManagerGenerationTests.manual-rejection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let audio = AudioManager(
            bpmOverrideStore: TrackBPMOverrideStore(defaults: defaults)
        )
        audio.targetBPM = 180
        await audio.loadSampleTrack(.warmupGroove)
        XCTAssertTrue(audio.isCurrentTempoPlayable)

        audio.play()
        XCTAssertEqual(audio.state, .playing)

        audio.setOriginalBPM(120)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(audio.state, .paused)
        XCTAssertEqual(audio.errorMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testPlayingDirectLocalTrackPausesAndShowsErrorWhenCadenceBecomesRejected() async {
        let audio = AudioManager()
        audio.targetBPM = 140
        await audio.loadSampleTrack(.clickLoop)
        XCTAssertTrue(audio.isCurrentTempoPlayable)

        audio.play()
        XCTAssertEqual(audio.state, .playing)

        audio.targetBPM = 180
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(audio.state, .paused)
        XCTAssertEqual(audio.errorMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testUnconfirmedLocalTrackCannotStartPlayback() async {
        let audio = AudioManager()
        audio.targetBPM = 180
        await audio.loadSampleTrack(.warmupGroove)
        audio.setStreamingBeatAlignment(
            bpm: nil,
            source: .assumedDefault,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.state, .ready)
        XCTAssertTrue(audio.hasLoadedTrack)
        XCTAssertEqual(audio.originalBPMSource, .assumedDefault)
        XCTAssertFalse(audio.canStartPlayback)

        audio.play()

        XCTAssertEqual(audio.state, .ready)
    }

    func testConfirmedRejectedPlaylistTrackMarksCurrentAndAdvances() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: true
        )

        XCTAssertEqual(action, .advance(playlist.currentItem!))
        XCTAssertEqual(playlist.currentItem?.title, "b")
        XCTAssertEqual(
            playlist.items.first(where: { $0.title == "a" })?.unplayableReason,
            .rateOutOfRange(required: audio.tempoPlan.requiredPlaybackRate)
        )
    }

    func testRejectedPlaylistPolicyWrapsOnceToRecoverEarlierCandidate() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        var playlist = LocalFilePlaylist(
            items: [
                QueueItem(
                    id: "a", title: "a", artist: nil,
                    source: .file(URL(fileURLWithPath: "/tmp/a.mp3"))
                ),
                QueueItem(
                    id: "b", title: "b", artist: nil,
                    source: .file(URL(fileURLWithPath: "/tmp/b.mp3"))
                ),
            ],
            currentIndex: 1
        )

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: true
        )

        XCTAssertEqual(action, .advance(playlist.currentItem!))
        XCTAssertEqual(playlist.currentItem?.title, "a")
        XCTAssertEqual(
            playlist.items.first(where: { $0.title == "b" })?.unplayableReason,
            .rateOutOfRange(required: audio.tempoPlan.requiredPlaybackRate)
        )
    }

    func testUnconfirmedPlaylistTrackDoesNotMarkOrAdvance() {
        let audio = AudioManager()
        audio.targetBPM = 180
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: true
        )

        XCTAssertEqual(action, .keepCurrent)
        XCTAssertEqual(playlist.currentItem?.title, "a")
        XCTAssertNil(playlist.currentItem?.unplayableReason)
    }

    func testRejectedPlaylistWithNoPlayableItemReportsExhausted() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        var playlist = LocalFilePlaylist(items: [
            QueueItem(
                id: "a", title: "a", artist: nil,
                source: .file(URL(fileURLWithPath: "/tmp/a.mp3"))
            ),
            QueueItem(
                id: "b", title: "b", artist: nil,
                source: .file(URL(fileURLWithPath: "/tmp/b.mp3")),
                unplayableReason: .rateOutOfRange(required: 1.7)
            ),
        ])

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: true
        )

        XCTAssertEqual(action, .exhausted)
        XCTAssertEqual(
            playlist.currentItem?.unplayableReason,
            .rateOutOfRange(required: audio.tempoPlan.requiredPlaybackRate)
        )
    }

    func testRejectedDirectTrackNeverAdvancesQueue() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: false
        )

        XCTAssertEqual(action, .rejectCurrent)
        XCTAssertEqual(playlist.currentItem?.title, "a")
        XCTAssertNil(playlist.currentItem?.unplayableReason)
        XCTAssertEqual(audio.tempoRejectionMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testRejectedOneItemPlaylistReturnsDirectRejectionWithoutMarkingOrAdvancing() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/only.mp3"),
        ])

        let action = audio.evaluateCurrentLocalTempoPolicy(
            playlist: &playlist,
            allowsAutomaticAdvance: true
        )

        XCTAssertEqual(action, .rejectCurrent)
        XCTAssertEqual(playlist.currentItem?.title, "only")
        XCTAssertNil(playlist.currentItem?.unplayableReason)
    }

    func testRejectedOneItemPlaylistLoadsWithoutAdvancingAndShowsDirectError() async throws {
        let audio = AudioManager()
        audio.targetBPM = 180
        await audio.loadSampleTrack(.clickLoop)
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let sampleURL = cachesDirectory.appendingPathComponent(SampleTrackPreset.clickLoop.filename)

        await audio.loadPlaylist(fileURLs: [sampleURL], autoPlay: true)

        XCTAssertEqual(audio.localPlaylist.count, 1)
        XCTAssertEqual(audio.localPlaylist.currentItem?.source, .file(sampleURL))
        XCTAssertNil(audio.localPlaylist.currentItem?.unplayableReason)
        XCTAssertNotEqual(audio.state, .playing)
        XCTAssertEqual(audio.errorMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testStreamingQueuePolicyContextTransitionsBetweenSongAndPlaylist() {
        var context = StreamingQueuePolicyContext.playlist(identity: "playlist-entry")

        context = .song(identity: "song")
        XCTAssertFalse(context.isPlaylist)
        XCTAssertEqual(context.identity, "song")

        context = .playlist(identity: "next-entry")
        XCTAssertTrue(context.isPlaylist)
        XCTAssertEqual(context.identity, "next-entry")
    }

    func testStreamingQueuePolicyContextClearsIdentityAndKindAfterFailure() {
        var context = StreamingQueuePolicyContext.playlist(identity: "playlist-entry")

        context.clearAfterFailure()

        XCTAssertFalse(context.isPlaylist)
        XCTAssertNil(context.identity)
    }

    func testStreamingQueueMutationGateSerializesSkipBeforeNewQueueSetup() async {
        let gate = StreamingQueueMutationGate()
        await gate.acquire()
        var didAcquireForSelection = false

        let selection = Task { @MainActor in
            await gate.acquire()
            didAcquireForSelection = true
            gate.release()
        }
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(didAcquireForSelection)

        gate.release()
        await selection.value

        XCTAssertTrue(didAcquireForSelection)
    }

    func testSupersededLocalLoadCannotCommitAfterNewerLoad() async throws {
        let suiteName = "AudioManagerGenerationTests.load-inversion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let overrideStore = TrackBPMOverrideStore(defaults: defaults)

        let preparer = AudioManager(bpmOverrideStore: overrideStore)
        await preparer.loadSampleTrack(.clickLoop)
        await preparer.loadSampleTrack(.warmupGroove)
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let firstURL = cachesDirectory.appendingPathComponent(SampleTrackPreset.clickLoop.filename)
        let secondURL = cachesDirectory.appendingPathComponent(SampleTrackPreset.warmupGroove.filename)
        let barrier = LocalLoadCommitBarrier(blockedURL: firstURL)
        let audio = AudioManager(
            bpmOverrideStore: overrideStore,
            localLoadCommitBarrier: { url in
                await barrier.suspendIfNeeded(url: url)
            }
        )
        audio.targetBPM = 180

        let firstLoad = Task { @MainActor in
            await audio.loadFile(url: firstURL)
        }
        await barrier.waitUntilSuspended()

        await audio.loadFile(url: secondURL)
        let secondTitle = audio.trackTitle
        let secondBPM = audio.originalBPM
        let secondDuration = audio.trackDuration
        let secondBeatStatus = audio.beatSyncStatus
        let secondCacheStatus = audio.beatAlignmentCacheStatus

        barrier.resume()
        _ = await firstLoad.value

        XCTAssertEqual(audio.state, .ready)
        XCTAssertEqual(audio.trackTitle, secondTitle)
        XCTAssertEqual(audio.trackTitle, "Cadenza-warmupGroove")
        XCTAssertEqual(audio.originalBPM, secondBPM)
        XCTAssertEqual(audio.originalBPM, 180, accuracy: 0.5)
        XCTAssertEqual(audio.trackDuration, secondDuration)
        XCTAssertEqual(audio.beatSyncStatus, secondBeatStatus)
        XCTAssertEqual(audio.beatAlignmentCacheStatus, secondCacheStatus)
        XCTAssertTrue(audio.hasBeatAlignmentAnalysis)
    }

    func testPreparingForStreamingInvalidatesSuspendedDirectLocalLoad() async throws {
        let preparer = AudioManager()
        await preparer.loadSampleTrack(.clickLoop)
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let localURL = cachesDirectory.appendingPathComponent(SampleTrackPreset.clickLoop.filename)
        let barrier = LocalLoadCommitBarrier(blockedURL: localURL)
        let audio = AudioManager(localLoadCommitBarrier: { url in
            await barrier.suspendIfNeeded(url: url)
        })

        let localLoad = Task { @MainActor in
            await audio.loadFile(url: localURL)
        }
        await barrier.waitUntilSuspended()
        XCTAssertEqual(audio.state, .loading)
        XCTAssertTrue(audio.hasActiveLocalTrackResource)

        audio.prepareForStreamingPlayback()
        audio.setStreamingBeatAlignment(
            bpm: 187,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        barrier.resume()
        let didLoad = await localLoad.value

        XCTAssertFalse(didLoad)
        XCTAssertEqual(audio.state, .idle)
        XCTAssertFalse(audio.hasLoadedTrack)
        XCTAssertFalse(audio.hasActiveLocalTrackResource)
        XCTAssertEqual(audio.originalBPM, 187, accuracy: 0.001)
        XCTAssertEqual(audio.originalBPMSource, .metadata)
    }

    func testPreparingForStreamingCleansSuspendedPlaylistLoad() async throws {
        let preparer = AudioManager()
        await preparer.loadSampleTrack(.clickLoop)
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let localURL = cachesDirectory.appendingPathComponent(SampleTrackPreset.clickLoop.filename)
        let barrier = LocalLoadCommitBarrier(blockedURL: localURL)
        let audio = AudioManager(localLoadCommitBarrier: { url in
            await barrier.suspendIfNeeded(url: url)
        })

        let playlistLoad = Task { @MainActor in
            await audio.loadPlaylist(fileURLs: [localURL])
        }
        await barrier.waitUntilSuspended()
        XCTAssertEqual(audio.state, .loading)
        XCTAssertTrue(audio.hasActiveLocalTrackResource)
        XCTAssertEqual(audio.localPlaylist.count, 1)

        audio.prepareForStreamingPlayback()
        barrier.resume()
        await playlistLoad.value

        XCTAssertEqual(audio.state, .idle)
        XCTAssertFalse(audio.hasLoadedTrack)
        XCTAssertFalse(audio.hasActiveLocalTrackResource)
        XCTAssertTrue(audio.localPlaylist.isEmpty)
    }

    func testPreparingForStreamingPreservesCommittedPausedLocalTrack() async {
        let suiteName = "AudioManagerGenerationTests.streaming-preserves-paused.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let audio = AudioManager(
            bpmOverrideStore: TrackBPMOverrideStore(defaults: defaults)
        )
        audio.targetBPM = 180
        await audio.loadSampleTrack(.warmupGroove)
        audio.play()
        audio.pause()
        let title = audio.trackTitle
        let bpm = audio.originalBPM

        audio.prepareForStreamingPlayback()

        XCTAssertEqual(audio.state, .paused)
        XCTAssertTrue(audio.hasLoadedTrack)
        XCTAssertTrue(audio.hasActiveLocalTrackResource)
        XCTAssertEqual(audio.trackTitle, title)
        XCTAssertEqual(audio.originalBPM, bpm, accuracy: 0.001)
    }

    func testStreamingControllerStartsOutsidePlaylistContextWithoutIdentity() {
        let streaming = AppleMusicStreamingController()

        XCTAssertFalse(streaming.isPlaylistQueueContext)
        XCTAssertNil(streaming.currentQueueIdentity)
    }

    func testStreamingNextReportsFailureWhenThereIsNoCurrentQueueEntry() async {
        let streaming = AppleMusicStreamingController()

        let didSkip = await streaming.skipToNext(playbackRate: 1.0)

        XCTAssertFalse(didSkip)
    }

    /// 스티키 케이던스: streaming BPM 해석이 도착해도 사용자의 케이던스는 유지된다.
    func testStreamingBeatAlignmentDoesNotOverwriteStickyCadence() {
        let audio = AudioManager()
        audio.targetBPM = 170

        audio.setStreamingBeatAlignment(
            bpm: 85,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        XCTAssertEqual(audio.targetBPM, 170)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)

        // 다른 곡(원곡 128)으로 바뀌어도 케이던스는 그대로.
        audio.setStreamingBeatAlignment(
            bpm: 128,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        XCTAssertEqual(audio.targetBPM, 170)
    }

    func testMetronomeRequiresConfirmedBPM() {
        let audio = AudioManager()

        // 기본 상태: needsConfirmation — BPM 확정 안 됨
        XCTAssertFalse(audio.canRunMetronomeForCurrentBeatSync)

        // BPM 확정 (grid 없이) — bpmOnly. 균등 간격 메트로놈은 가능해야 함.
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.beatSyncStatus, .bpmOnly)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)

        // grid까지 신뢰: automaticBeatSync — 정확한 박자 정렬 가능.
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .analysis,
            beatOffsetSeconds: 0.1,
            beatTimesSeconds: [0.1, 0.6, 1.1, 1.6],
            confidence: 0.8
        )

        XCTAssertEqual(audio.beatSyncStatus, .automaticBeatSync)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
    }

    func testLowConfidenceBeatGridFallsBackToBPMOnlyMetronome() {
        let audio = AudioManager()

        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .analysis,
            beatOffsetSeconds: 0.1,
            beatTimesSeconds: [0.1, 0.6, 1.1, 1.6],
            confidence: 0.2
        )

        XCTAssertEqual(audio.beatSyncStatus, .bpmOnly)
        XCTAssertEqual(audio.beatSyncIssue, .lowConfidence)
        // 새 정책: 신뢰도 낮아도 BPM은 확정된 상태이므로 균등 간격 메트로놈은 동작.
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
    }
}

@MainActor
private final class LocalLoadCommitBarrier {
    private let blockedURL: URL
    private var isSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockedURL: URL) {
        self.blockedURL = blockedURL.standardizedFileURL
    }

    func suspendIfNeeded(url: URL) async {
        guard url.standardizedFileURL == blockedURL else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isSuspended = true
        }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
        isSuspended = false
    }
}
