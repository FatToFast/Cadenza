package com.jy.cadenza.android

import android.app.Application
import android.content.ComponentName
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class BpmStatus {
    IDLE,
    ANALYZING,
    METADATA,
    DETECTED,
    FAILED,
    MANUAL,
}

data class CadenzaUiState(
    val serverUrl: String = "",
    val videoUrl: String = "",
    val trackName: String? = null,
    val trackArtist: String? = null,
    val trackNames: List<String> = emptyList(),
    val currentTrackIndex: Int = -1,
    val originalBpm: Float = 120f,
    val targetBpm: Float = 180f,
    val effectiveCadence: Float = 180f,
    val playbackRate: Float = 1f,
    val bpmStatus: BpmStatus = BpmStatus.IDLE,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val isPlaying: Boolean = false,
    val playerReady: Boolean = false,
    val shuffleEnabled: Boolean = false,
    val repeatEnabled: Boolean = false,
    val metronomeEnabled: Boolean = false,
    val metronomeVolume: Float = 0.6f,
    val downloadStatus: String? = null,
    val downloadProgress: Int? = null,
    val isDownloading: Boolean = false,
    val error: String? = null,
)

data class LocalTrack(val uri: Uri, val name: String)

class CadenzaViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("cadenza", 0)
    private val downloader = DownloadClient(application)
    private val bpmStore = BpmStore(application)
    private val playlistStore = LocalPlaylistStore(application)
    private val restoredPlaylist = playlistStore.load()
    private var tone = ToneGenerator(AudioManager.STREAM_MUSIC, 60)
    private val controllerFuture = MediaController.Builder(
        application,
        SessionToken(application, ComponentName(application, PlaybackService::class.java)),
    ).buildAsync()
    private var controller: MediaController? = null
    private var tracks: List<LocalTrack> = restoredPlaylist?.tracks.orEmpty()
    private var pendingTracks: List<LocalTrack>? = null
    private var pendingTrackIndex = 0
    private var bpmAnalysisJob: Job? = null
    private var activeBpmAnalysisUri: Uri? = null
    private var bpmGeneration = 0
    private var metronomeJob: Job? = null

    private val _state = MutableStateFlow(initialUiState())
    val state: StateFlow<CadenzaUiState> = _state.asStateFlow()

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _state.update { it.copy(isPlaying = isPlaying) }
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            val index = controller?.currentMediaItemIndex ?: C.INDEX_UNSET
            syncCurrentTrack(index, resetPosition = true)
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            refreshProgress()
        }

        override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
            _state.update { it.copy(shuffleEnabled = shuffleModeEnabled) }
        }

        override fun onRepeatModeChanged(repeatMode: Int) {
            _state.update { it.copy(repeatEnabled = repeatMode == Player.REPEAT_MODE_ALL) }
        }
    }

    init {
        val mainExecutor = java.util.concurrent.Executor { command ->
            Handler(Looper.getMainLooper()).post(command)
        }
        controllerFuture.addListener(
            {
                runCatching { controllerFuture.get() }
                    .onSuccess { mediaController ->
                        controller = mediaController
                        mediaController.addListener(playerListener)
                        _state.update { it.copy(playerReady = true) }
                        val pending = pendingTracks
                        when {
                            pending != null -> configurePlaylist(pending, pendingTrackIndex)
                            mediaController.mediaItemCount > 0 -> restoreQueueFromController(mediaController)
                            tracks.isNotEmpty() -> configurePlaylist(
                                tracks,
                                restoredPlaylist?.currentIndex ?: 0,
                            )
                        }
                        pendingTracks = null
                    }
                    .onFailure { throwable ->
                        _state.update { it.copy(error = throwable.message ?: "플레이어에 연결할 수 없습니다") }
                    }
            },
            mainExecutor,
        )

        viewModelScope.launch {
            while (isActive) {
                refreshProgress()
                delay(500)
            }
        }
    }

    fun setServerUrl(value: String) = _state.update { it.copy(serverUrl = value) }
    fun setVideoUrl(value: String) = _state.update { it.copy(videoUrl = value) }

    fun setOriginalBpm(value: Float) {
        if (!value.isFinite() || value <= 0f) return
        bpmAnalysisJob?.cancel()
        activeBpmAnalysisUri = null
        bpmGeneration += 1
        _state.update { it.copy(bpmStatus = BpmStatus.MANUAL) }
        tracks.getOrNull(_state.value.currentTrackIndex)?.let { track ->
            viewModelScope.launch(Dispatchers.IO) {
                bpmStore.put(track, value, BpmStatus.MANUAL)
            }
        }
        updateTempo(original = value, target = _state.value.targetBpm)
    }

    fun setTargetBpm(value: Float) {
        val normalized = value.coerceIn(140f, 220f)
        preferences.edit().putFloat(TARGET_BPM_KEY, normalized).apply()
        updateTempo(original = _state.value.originalBpm, target = normalized)
    }

    fun nudgeTargetBpm(delta: Float) {
        setTargetBpm((_state.value.targetBpm + delta).coerceIn(140f, 220f))
    }

    fun resetTargetBpm() = setTargetBpm(180f)

    fun loadLocalUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val selectedTracks = withContext(Dispatchers.IO) {
                uris.map { uri ->
                    runCatching {
                        getApplication<Application>().contentResolver.takePersistableUriPermission(
                            uri,
                            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    }
                    LocalTrack(uri, displayNameForUri(uri))
                }
            }
            load(selectedTracks)
        }
    }

    fun selectTrack(index: Int) {
        if (index !in tracks.indices) return
        controller?.run {
            seekToDefaultPosition(index)
            play()
        }
    }

    fun nextTrack() {
        controller?.seekToNextMediaItem()
    }

    fun toggleShuffle() {
        val player = controller ?: return
        player.shuffleModeEnabled = !player.shuffleModeEnabled
    }

    fun toggleRepeat() {
        val player = controller ?: return
        player.repeatMode = if (player.repeatMode == Player.REPEAT_MODE_ALL) {
            Player.REPEAT_MODE_OFF
        } else {
            Player.REPEAT_MODE_ALL
        }
    }

    fun previousTrack() {
        controller?.run {
            if (currentPosition > 3_000) seekTo(0) else seekToPreviousMediaItem()
        }
    }

    fun seekTo(positionMs: Long) {
        controller?.seekTo(positionMs.coerceIn(0, _state.value.durationMs.coerceAtLeast(0)))
        refreshProgress()
    }

    fun reanalyzeCurrentTrack() {
        val index = _state.value.currentTrackIndex
        val track = tracks.getOrNull(index) ?: return
        viewModelScope.launch {
            withContext(Dispatchers.IO) { bpmStore.remove(track) }
            if (tracks.getOrNull(index)?.uri == track.uri) {
                startBpmAnalysis(index, force = true)
            }
        }
    }

    fun downloadMp3() {
        val snapshot = _state.value
        if (snapshot.serverUrl.isBlank() || snapshot.videoUrl.isBlank()) {
            _state.update { it.copy(error = "서버 주소와 YouTube URL을 모두 입력하세요") }
            return
        }
        preferences.edit().putString("server_url", snapshot.serverUrl.trim()).apply()
        _state.update {
            it.copy(isDownloading = true, error = null, downloadStatus = "queued", downloadProgress = 0)
        }
        viewModelScope.launch {
            runCatching {
                downloader.download(snapshot.serverUrl.trim(), snapshot.videoUrl.trim()) { status, progress ->
                    _state.update { it.copy(downloadStatus = status, downloadProgress = progress) }
                }
            }.onSuccess { result ->
                load(listOf(LocalTrack(result.uri, result.filename)))
                _state.update {
                    it.copy(isDownloading = false, downloadStatus = "ready", downloadProgress = 100)
                }
            }.onFailure { throwable ->
                _state.update {
                    it.copy(isDownloading = false, error = throwable.message ?: "MP3를 받을 수 없습니다")
                }
            }
        }
    }

    fun togglePlayback() {
        val player = controller
        if (tracks.isEmpty() || player == null) {
            _state.update { it.copy(error = "먼저 MP3 파일을 선택하거나 받아주세요") }
            return
        }
        if (player.isPlaying) player.pause() else player.play()
    }

    fun setMetronomeEnabled(enabled: Boolean) {
        _state.update { it.copy(metronomeEnabled = enabled) }
        if (enabled) startMetronome() else stopMetronome()
    }

    fun setMetronomeVolume(value: Float) {
        val normalized = value.coerceIn(0f, 1f)
        tone.release()
        tone = ToneGenerator(AudioManager.STREAM_MUSIC, (normalized * 100).toInt())
        _state.update { it.copy(metronomeVolume = normalized) }
        if (_state.value.metronomeEnabled) startMetronome()
    }

    fun clearError() = _state.update { it.copy(error = null) }

    private fun load(selectedTracks: List<LocalTrack>) {
        val sortedTracks = selectedTracks.sortedBy { it.name.lowercase() }
        bpmAnalysisJob?.cancel()
        activeBpmAnalysisUri = null
        bpmGeneration += 1
        tracks = sortedTracks
        pendingTracks = sortedTracks
        pendingTrackIndex = 0
        playlistStore.save(sortedTracks, 0)
        val firstMetadata = displayMetadata(sortedTracks.first())
        _state.update {
            it.copy(
                trackName = firstMetadata.title,
                trackArtist = firstMetadata.artist,
                trackNames = sortedTracks.map { track -> displayMetadata(track).title },
                currentTrackIndex = 0,
                originalBpm = 120f,
                effectiveCadence = it.targetBpm,
                playbackRate = 1f,
                bpmStatus = BpmStatus.ANALYZING,
                positionMs = 0,
                durationMs = 0,
                error = null,
            )
        }
        applyPlaybackRate(1f)
        controller?.let {
            configurePlaylist(sortedTracks, 0)
            pendingTracks = null
        }
    }

    private fun configurePlaylist(selectedTracks: List<LocalTrack>, startIndex: Int) {
        controller?.run {
            val mediaItems = selectedTracks.map { track ->
                val metadata = displayMetadata(track)
                MediaItem.Builder()
                    .setMediaId(track.uri.toString())
                    .setUri(track.uri)
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(metadata.title)
                            .setArtist(metadata.artist)
                            .build(),
                    )
                    .build()
            }
            val normalizedIndex = startIndex.coerceIn(selectedTracks.indices)
            setMediaItems(
                mediaItems,
                normalizedIndex,
                C.TIME_UNSET,
            )
            prepare()
            playbackParameters = PlaybackParameters(_state.value.playbackRate, 1f)
            syncCurrentTrack(normalizedIndex, resetPosition = true)
        }
    }

    private fun startBpmAnalysis(
        index: Int,
        force: Boolean = false,
        preserveCurrentRate: Boolean = false,
    ) {
        val track = tracks.getOrNull(index) ?: return
        if (!force && activeBpmAnalysisUri == track.uri && bpmAnalysisJob?.isActive == true) return
        bpmAnalysisJob?.cancel()
        activeBpmAnalysisUri = track.uri
        bpmGeneration += 1
        val generation = bpmGeneration

        _state.update {
            it.copy(
                bpmStatus = BpmStatus.ANALYZING,
                originalBpm = 120f,
                effectiveCadence = if (preserveCurrentRate) it.effectiveCadence else it.targetBpm,
                playbackRate = if (preserveCurrentRate) it.playbackRate else 1f,
            )
        }
        if (!preserveCurrentRate) applyPlaybackRate(1f)
        bpmAnalysisJob = viewModelScope.launch {
            try {
                val saved = if (force) null else withContext(Dispatchers.IO) { bpmStore.get(track) }
                if (saved != null) {
                    if (generation == bpmGeneration && _state.value.currentTrackIndex == index) {
                        applyBpmResult(index, saved.bpm, saved.status)
                    }
                    return@launch
                }

                val metadataBpm = if (force) null else BpmMetadataReader.read(getApplication(), track.uri)
                val bpm = metadataBpm ?: BpmAnalyzer.analyze(getApplication(), track.uri)
                val status = if (metadataBpm != null) BpmStatus.METADATA else BpmStatus.DETECTED
                if (bpm != null) {
                    withContext(Dispatchers.IO) { bpmStore.put(track, bpm, status) }
                }
                if (generation == bpmGeneration && _state.value.currentTrackIndex == index) {
                    applyBpmResult(index, bpm, status)
                }
            } finally {
                if (generation == bpmGeneration) activeBpmAnalysisUri = null
            }
        }
    }

    private fun applyBpmResult(index: Int, bpm: Float?, status: BpmStatus = BpmStatus.DETECTED) {
        if (_state.value.currentTrackIndex != index) return
        if (bpm == null) {
            _state.update {
                it.copy(bpmStatus = BpmStatus.FAILED, originalBpm = 120f, playbackRate = 1f)
            }
            applyPlaybackRate(1f)
            return
        }

        val plan = PlaybackRatePolicy.plan(bpm, _state.value.targetBpm)
        _state.update {
            it.copy(
                originalBpm = bpm,
                effectiveCadence = plan.effectiveCadence,
                playbackRate = plan.rate,
                bpmStatus = status,
            )
        }
        applyPlaybackRate(plan.rate)
    }

    private fun updateTempo(original: Float, target: Float) {
        val canAdjustPlayback = _state.value.bpmStatus in
            setOf(BpmStatus.METADATA, BpmStatus.DETECTED, BpmStatus.MANUAL)
        val plan = if (canAdjustPlayback) {
            PlaybackRatePolicy.plan(original, target)
        } else {
            PlaybackTempoPlan(rate = 1f, effectiveCadence = target)
        }
        _state.update {
            it.copy(
                originalBpm = original,
                targetBpm = target,
                effectiveCadence = plan.effectiveCadence,
                playbackRate = plan.rate,
            )
        }
        applyPlaybackRate(plan.rate)
    }

    private fun applyPlaybackRate(rate: Float) {
        controller?.playbackParameters = PlaybackParameters(rate, 1f)
    }

    private fun refreshProgress() {
        val player = controller ?: return
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0
        _state.update {
            it.copy(
                positionMs = player.currentPosition.coerceAtLeast(0),
                durationMs = duration,
                isPlaying = player.isPlaying,
            )
        }
    }

    private fun startMetronome() {
        stopMetronome()
        metronomeJob = viewModelScope.launch {
            while (isActive && _state.value.metronomeEnabled) {
                tone.startTone(ToneGenerator.TONE_PROP_BEEP, 45)
                val interval = (60_000f / _state.value.effectiveCadence.coerceAtLeast(1f)).toLong()
                delay(interval)
            }
        }
    }

    private fun stopMetronome() {
        metronomeJob?.cancel()
        metronomeJob = null
    }

    private data class DisplayMetadata(val title: String, val artist: String?)

    private fun initialUiState(): CadenzaUiState {
        val targetBpm = preferences.getFloat(TARGET_BPM_KEY, 180f).coerceIn(140f, 220f)
        val currentIndex = restoredPlaylist?.currentIndex?.takeIf { it in tracks.indices } ?: 0
        val metadata = tracks.getOrNull(currentIndex)?.let(::displayMetadata)
        return CadenzaUiState(
            serverUrl = preferences.getString("server_url", "") ?: "",
            trackName = metadata?.title,
            trackArtist = metadata?.artist,
            trackNames = tracks.map { track -> displayMetadata(track).title },
            currentTrackIndex = if (tracks.isEmpty()) -1 else currentIndex,
            targetBpm = targetBpm,
            effectiveCadence = targetBpm,
        )
    }

    private fun restoreQueueFromController(player: MediaController) {
        val knownTracks = tracks.associateBy { it.uri.toString() }
        val restoredTracks = (0 until player.mediaItemCount).mapNotNull { index ->
            val item = player.getMediaItemAt(index)
            val uri = item.localConfiguration?.uri
                ?: item.mediaId.takeIf(String::isNotBlank)?.let(Uri::parse)
                ?: return@mapNotNull null
            knownTracks[uri.toString()] ?: LocalTrack(
                uri = uri,
                name = buildString {
                    item.mediaMetadata.artist?.takeIf { it.isNotBlank() }?.let { append("$it - ") }
                    append(item.mediaMetadata.title?.takeIf { it.isNotBlank() } ?: "선택한 음악")
                    append(".mp3")
                },
            )
        }
        if (restoredTracks.isEmpty()) return
        tracks = restoredTracks
        val index = player.currentMediaItemIndex.coerceIn(restoredTracks.indices)
        playlistStore.save(restoredTracks, index)
        syncCurrentTrack(index, resetPosition = false, preserveCurrentRate = true)
    }

    private fun syncCurrentTrack(
        index: Int,
        resetPosition: Boolean,
        preserveCurrentRate: Boolean = false,
    ) {
        if (index !in tracks.indices) return
        val metadata = displayMetadata(tracks[index])
        val player = controller
        _state.update {
            it.copy(
                trackName = metadata.title,
                trackArtist = metadata.artist,
                trackNames = tracks.map { track -> displayMetadata(track).title },
                currentTrackIndex = index,
                positionMs = if (resetPosition) 0 else player?.currentPosition?.coerceAtLeast(0) ?: 0,
                isPlaying = player?.isPlaying ?: false,
                playbackRate = if (preserveCurrentRate) {
                    player?.playbackParameters?.speed ?: it.playbackRate
                } else {
                    it.playbackRate
                },
                shuffleEnabled = player?.shuffleModeEnabled ?: false,
                repeatEnabled = player?.repeatMode == Player.REPEAT_MODE_ALL,
            )
        }
        playlistStore.save(tracks, index)
        startBpmAnalysis(index, preserveCurrentRate = preserveCurrentRate)
    }

    private fun displayNameForUri(uri: Uri): String {
        val resolver = getApplication<Application>().contentResolver
        return runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
            }
        }.getOrNull()?.takeIf(String::isNotBlank)
            ?: uri.lastPathSegment
            ?: "선택한 음악"
    }

    private fun displayMetadata(track: LocalTrack): DisplayMetadata {
        val baseName = track.name.substringBeforeLast('.').ifBlank { track.name }
        val parts = baseName.split(" - ", limit = 2)
        return if (parts.size == 2) {
            DisplayMetadata(title = parts[1], artist = parts[0])
        } else {
            DisplayMetadata(title = baseName, artist = null)
        }
    }

    override fun onCleared() {
        bpmAnalysisJob?.cancel()
        stopMetronome()
        tone.release()
        controller?.removeListener(playerListener)
        MediaController.releaseFuture(controllerFuture)
    }

    private companion object {
        const val TARGET_BPM_KEY = "target_bpm"
    }
}
