@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.jy.cadenza.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

private val CadenzaBackground = Color(0xFF0A0A0F)
private val CadenzaSecondary = Color(0xFF1A1A22)
private val CadenzaAccent = Color(0xFF00E5C7)
private val CadenzaWarning = Color(0xFFFF8A3D)
private val CadenzaTextPrimary = Color(0xFFF5F5F7)
private val CadenzaTextSecondary = Color(0xFF9A9AA5)
private val CadenzaTextTertiary = Color(0xFF5A5A65)
private val CadenzaDivider = Color(0xFF2A2A35)
private val CadenzaColors = darkColorScheme(
    primary = CadenzaAccent,
    background = CadenzaBackground,
    surface = CadenzaSecondary,
    onPrimary = CadenzaBackground,
    onBackground = CadenzaTextPrimary,
    onSurface = CadenzaTextPrimary,
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = CadenzaColors) { CadenzaScreen() }
        }
    }
}

@Composable
private fun CadenzaScreen(viewModel: CadenzaViewModel = viewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var showQueue by remember { mutableStateOf(false) }
    var showDownload by remember { mutableStateOf(false) }

    val singlePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { viewModel.loadLocalUris(listOf(it)) }
    }
    val playlistPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.loadLocalUris(uris)
    }

    Box(Modifier.fillMaxSize().background(CadenzaBackground)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Text(
                "Cadenza",
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
                color = CadenzaTextPrimary,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
            )
            CadenzaRule()

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding(),
            ) {
                TrackHero(state = state, viewModel = viewModel, onShowQueue = { showQueue = true })

                BpmDisplay(state)

                CadenceControl(state = state, viewModel = viewModel)

                if (state.trackName != null && state.durationMs > 0) {
                    CadenzaRule()
                    PlaybackProgress(state = state, onSeek = viewModel::seekTo)
                }

                if (state.trackName != null) {
                    CadenzaRule()
                    OriginalBpmControl(state = state, viewModel = viewModel)
                    CadenzaRule()
                    BeatStatus(state)
                }

                CadenzaRule()
                PlaybackControls(state = state, viewModel = viewModel)

                CadenzaRule()
                MetronomeControls(state = state, viewModel = viewModel)

                CadenzaRule()
                SelectionControls(
                    hasQueue = state.trackNames.isNotEmpty(),
                    onSingle = { singlePicker.launch(arrayOf("audio/mpeg", "audio/mp3", "audio/mp4", "audio/wav")) },
                    onPlaylist = { playlistPicker.launch(arrayOf("audio/mpeg", "audio/mp3", "audio/mp4", "audio/wav")) },
                    onDownload = { showDownload = true },
                    onQueue = { showQueue = true },
                )
            }
        }

        state.error?.let { message ->
            ErrorBanner(message = message, onDismiss = viewModel::clearError)
        }
    }

    if (showQueue) {
        QueueSheet(
            state = state,
            onDismiss = { showQueue = false },
            onSelect = { index ->
                viewModel.selectTrack(index)
                showQueue = false
            },
        )
    }

    if (showDownload) {
        DownloadSheet(
            state = state,
            viewModel = viewModel,
            onDismiss = { showDownload = false },
        )
    }
}

@Composable
private fun TrackHero(state: CadenzaUiState, viewModel: CadenzaViewModel, onShowQueue: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (state.trackName == null) {
            Spacer(Modifier.height(20.dp))
            Icon(Icons.Default.MusicNote, contentDescription = null, tint = CadenzaTextTertiary, modifier = Modifier.size(34.dp))
            Text(
                "음악을 선택하거나\n메트로놈만 사용하세요",
                color = CadenzaTextTertiary,
                fontSize = 16.sp,
                textAlign = TextAlign.Center,
            )
            Text("지원 형식: mp3, m4a, wav", color = CadenzaTextSecondary, fontSize = 13.sp)
            PlaybackControls(state = state, viewModel = viewModel)
            Spacer(Modifier.height(12.dp))
        } else {
            Text(
                state.trackName,
                color = CadenzaTextPrimary,
                fontSize = 26.sp,
                fontWeight = FontWeight.ExtraBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
            state.trackArtist?.let { artist ->
                Text(artist, color = CadenzaTextSecondary, fontSize = 16.sp, maxLines = 1)
            }
            CadenceArtwork(bpm = state.originalBpm.roundToInt(), active = state.isPlaying)
            PlaybackControls(state = state, viewModel = viewModel)
            Text(
                "♫  키 락 ON",
                color = CadenzaAccent,
                fontSize = 13.sp,
                modifier = Modifier
                    .background(CadenzaAccent.copy(alpha = 0.15f), CircleShape)
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
            if (state.trackNames.size > 1) {
                TextButton(onClick = onShowQueue) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null, tint = CadenzaTextSecondary)
                    Text(
                        "  ${state.currentTrackIndex + 1} / ${state.trackNames.size}",
                        color = CadenzaTextSecondary,
                        fontSize = 13.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun CadenceArtwork(bpm: Int, active: Boolean) {
    Box(
        modifier = Modifier
            .size(220.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF0F0F14)),
    ) {
        Text(
            "CADENCE",
            modifier = Modifier.padding(12.dp),
            color = CadenzaTextTertiary,
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            letterSpacing = 2.sp,
        )
        Canvas(Modifier.fillMaxSize().padding(18.dp)) {
            val radius = size.minDimension * 0.43f
            drawCircle(CadenzaAccent.copy(alpha = 0.15f), radius, style = Stroke(width = 2.2f))
            drawCircle(CadenzaAccent.copy(alpha = 0.25f), radius * 0.74f, style = Stroke(width = 2.4f))
            drawCircle(CadenzaAccent.copy(alpha = 0.50f), radius * 0.50f, style = Stroke(width = 2.8f))
            drawCircle(CadenzaAccent.copy(alpha = if (active) 1f else 0.82f), radius * 0.11f)
        }
        Text(
            "$bpm BPM",
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
            color = CadenzaTextSecondary,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
        )
    }
}

@Composable
private fun BpmDisplay(state: CadenzaUiState) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            state.effectiveCadence.roundToInt().toString(),
            color = CadenzaAccent,
            fontSize = 56.sp,
            fontWeight = FontWeight.Bold,
        )
        Text("SPM", color = CadenzaTextSecondary, fontFamily = FontFamily.Monospace, fontSize = 10.sp, letterSpacing = 2.sp)
        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "원곡 ${state.originalBpm.roundToInt()} BPM",
                color = CadenzaTextTertiary,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            )
            Text(
                bpmPillText(state.bpmStatus),
                color = bpmStatusColor(state.bpmStatus),
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                modifier = Modifier
                    .background(bpmStatusColor(state.bpmStatus).copy(alpha = 0.12f), CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
        Text(
            "목표 ${state.targetBpm.roundToInt()} SPM",
            color = CadenzaTextSecondary,
            fontFamily = FontFamily.Monospace,
            fontSize = 13.sp,
        )
        if (abs(state.effectiveCadence - state.targetBpm) > 0.5f) {
            Text(
                "원곡 속도 유지 · 실제 ${state.effectiveCadence.roundToInt()} SPM",
                color = CadenzaWarning,
                fontSize = 13.sp,
            )
        }
        Text(
            bpmHelperText(state.bpmStatus),
            color = CadenzaTextSecondary,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp),
        )
        Text(
            "재생속도 ×${String.format(Locale.US, "%.2f", state.playbackRate)}",
            color = CadenzaTextTertiary,
            fontFamily = FontFamily.Monospace,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun CadenceControl(state: CadenzaUiState, viewModel: CadenzaViewModel) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("목표 케이던스", color = CadenzaTextPrimary, fontSize = 16.sp)
            Text(
                "${state.targetBpm.roundToInt()} SPM",
                color = CadenzaAccent,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            )
        }
        CadenzaSlider(
            value = state.targetBpm,
            onValueChange = viewModel::setTargetBpm,
            valueRange = 140f..220f,
            steps = 79,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("140", color = CadenzaTextTertiary, fontSize = 13.sp)
            Text("220", color = CadenzaTextTertiary, fontSize = 13.sp)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            QuickButton("-1") { viewModel.nudgeTargetBpm(-1f) }
            QuickButton("180", emphasized = state.targetBpm.roundToInt() == 180, onClick = viewModel::resetTargetBpm)
            QuickButton("+1") { viewModel.nudgeTargetBpm(1f) }
            Spacer(Modifier.weight(1f))
            Text(
                "현재 ${String.format(Locale.US, "%.2fx", state.playbackRate)}",
                color = CadenzaTextSecondary,
                fontSize = 13.sp,
            )
        }
    }
}

@Composable
private fun PlaybackProgress(state: CadenzaUiState, onSeek: (Long) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp)) {
        CadenzaSlider(
            value = state.positionMs.coerceIn(0, state.durationMs).toFloat(),
            onValueChange = { onSeek(it.toLong()) },
            valueRange = 0f..state.durationMs.toFloat().coerceAtLeast(1f),
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Timecode(state.positionMs, CadenzaTextSecondary)
            Timecode(state.durationMs, CadenzaTextTertiary)
        }
    }
}

@Composable
private fun OriginalBpmControl(state: CadenzaUiState, viewModel: CadenzaViewModel) {
    var bpmText by remember(state.currentTrackIndex, state.originalBpm.roundToInt()) {
        mutableStateOf(state.originalBpm.roundToInt().toString())
    }
    val parsed = bpmText.toFloatOrNull()
    val canApply = parsed != null && parsed in 60f..220f

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("원본 BPM", color = CadenzaTextPrimary, fontSize = 16.sp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(bpmStatusLabel(state.bpmStatus), color = bpmStatusColor(state.bpmStatus), fontSize = 13.sp)
                IconButton(onClick = viewModel::reanalyzeCurrentTrack, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Default.Refresh, contentDescription = "BPM 다시 분석", tint = CadenzaTextSecondary)
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = bpmText,
                onValueChange = { bpmText = it.filter(Char::isDigit).take(3) },
                modifier = Modifier.weight(1f),
                placeholder = { Text("예: 172") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                colors = cadenzaTextFieldColors(),
            )
            Button(
                onClick = { parsed?.let(viewModel::setOriginalBpm) },
                enabled = canApply,
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = CadenzaAccent, contentColor = CadenzaBackground),
            ) {
                Text("적용", fontSize = 13.sp)
            }
        }
        Text(bpmHelperText(state.bpmStatus), color = CadenzaTextSecondary, fontSize = 13.sp)
    }
}

@Composable
private fun BeatStatus(state: CadenzaUiState) {
    val detected = state.bpmStatus in setOf(BpmStatus.METADATA, BpmStatus.DETECTED)
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("박자 상태", color = CadenzaTextPrimary, fontSize = 16.sp)
            Text(if (detected) "BPM 동기화" else bpmStatusLabel(state.bpmStatus), color = if (detected) CadenzaAccent else CadenzaTextSecondary, fontSize = 13.sp)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            BeatMetric("신뢰도", if (detected) "감지됨" else "확인 중")
            BeatMetric("방식", if (detected) "BPM 간격" else "대기")
        }
        Text(
            if (detected) "BPM을 확인했으며 목표 케이던스에 맞춰 재생 속도를 조정합니다."
            else "분석이 끝나기 전에는 원곡 속도 1.00×를 유지합니다.",
            color = CadenzaTextSecondary,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun BeatMetric(label: String, value: String) {
    Column {
        Text(label, color = CadenzaTextTertiary, fontSize = 11.sp)
        Text(value, color = CadenzaTextSecondary, fontFamily = FontFamily.Monospace, fontSize = 13.sp)
    }
}

@Composable
private fun PlaybackControls(state: CadenzaUiState, viewModel: CadenzaViewModel) {
    val hasTrack = state.trackName != null
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 20.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PlayerCircleButton(
            icon = Icons.Default.Shuffle,
            description = if (state.shuffleEnabled) "셔플 끄기" else "셔플 켜기",
            enabled = state.trackNames.size > 1,
            selected = state.shuffleEnabled,
            onClick = viewModel::toggleShuffle,
        )
        Spacer(Modifier.width(10.dp))
        PlayerCircleButton(
            icon = Icons.Default.FastRewind,
            description = "이전 곡",
            enabled = hasTrack,
            onClick = viewModel::previousTrack,
        )
        Spacer(Modifier.width(14.dp))
        Button(
            onClick = viewModel::togglePlayback,
            enabled = hasTrack && state.playerReady,
            modifier = Modifier.size(80.dp),
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = CadenzaAccent,
                contentColor = CadenzaBackground,
                disabledContainerColor = CadenzaTextTertiary,
                disabledContentColor = CadenzaBackground,
            ),
        ) {
            Icon(
                if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                contentDescription = if (state.isPlaying) "일시정지" else "재생",
                modifier = Modifier.size(38.dp),
            )
        }
        Spacer(Modifier.width(14.dp))
        PlayerCircleButton(
            icon = Icons.Default.FastForward,
            description = "다음 곡",
            enabled = hasTrack,
            onClick = viewModel::nextTrack,
        )
        Spacer(Modifier.width(10.dp))
        PlayerCircleButton(
            icon = Icons.Default.Repeat,
            description = if (state.repeatEnabled) "반복 끄기" else "반복 켜기",
            enabled = hasTrack,
            selected = state.repeatEnabled,
            onClick = viewModel::toggleRepeat,
        )
    }
}

@Composable
private fun PlayerCircleButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    enabled: Boolean,
    selected: Boolean = false,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .size(52.dp)
            .background(if (selected) CadenzaAccent else CadenzaSecondary, CircleShape)
            .border(1.dp, CadenzaDivider, CircleShape)
            .alpha(if (enabled) 1f else 0.45f),
    ) {
        Icon(icon, contentDescription = description, tint = if (selected) CadenzaBackground else CadenzaAccent, modifier = Modifier.size(24.dp))
    }
}

@Composable
private fun MetronomeControls(state: CadenzaUiState, viewModel: CadenzaViewModel) {
    var previewVolume by remember(state.metronomeVolume) { mutableFloatStateOf(state.metronomeVolume) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("메트로놈", color = CadenzaTextPrimary, fontSize = 16.sp)
            Switch(
                checked = state.metronomeEnabled,
                onCheckedChange = viewModel::setMetronomeEnabled,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = CadenzaBackground,
                    checkedTrackColor = CadenzaAccent,
                    uncheckedThumbColor = CadenzaTextSecondary,
                    uncheckedTrackColor = CadenzaSecondary,
                    uncheckedBorderColor = CadenzaDivider,
                ),
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("클릭", color = CadenzaTextSecondary, fontSize = 13.sp)
            Text("${state.effectiveCadence.roundToInt()} BPM", color = CadenzaTextTertiary, fontSize = 13.sp)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("볼륨", color = CadenzaTextSecondary, fontSize = 13.sp)
            Text("${(previewVolume * 100).roundToInt()}%", color = CadenzaTextTertiary, fontSize = 13.sp)
        }
        CadenzaSlider(
            value = previewVolume,
            onValueChange = { previewVolume = it },
            onValueChangeFinished = { viewModel.setMetronomeVolume(previewVolume) },
            valueRange = 0f..1f,
        )
    }
}

@Composable
private fun SelectionControls(
    hasQueue: Boolean,
    onSingle: () -> Unit,
    onPlaylist: () -> Unit,
    onDownload: () -> Unit,
    onQueue: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SelectionButton("파일 선택", Icons.Default.FolderOpen, Modifier.weight(1f), onClick = onSingle)
            SelectionButton("MP3 플레이리스트", Icons.AutoMirrored.Filled.QueueMusic, Modifier.weight(1f), onClick = onPlaylist)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SelectionButton("MP3 받기", Icons.Default.CloudDownload, Modifier.weight(1f), onClick = onDownload)
            SelectionButton("재생 목록", Icons.Default.MusicNote, Modifier.weight(1f), enabled = hasQueue, onClick = onQueue)
        }
        Spacer(Modifier.height(20.dp))
    }
}

@Composable
private fun SelectionButton(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    modifier: Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(44.dp),
        enabled = enabled,
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, CadenzaDivider),
        contentPadding = PaddingValues(horizontal = 8.dp),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = CadenzaAccent),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Text("  $title", fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun QueueSheet(state: CadenzaUiState, onDismiss: () -> Unit, onSelect: (Int) -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = CadenzaBackground) {
        Column(Modifier.fillMaxWidth().heightIn(max = 620.dp).navigationBarsPadding()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("재생 목록", color = CadenzaTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "닫기", tint = CadenzaTextSecondary) }
            }
            HorizontalDivider(color = CadenzaDivider)
            if (state.trackNames.isEmpty()) {
                Text("선택한 곡이 없습니다", color = CadenzaTextTertiary, modifier = Modifier.padding(24.dp))
            } else {
                LazyColumn {
                    itemsIndexed(state.trackNames) { index, name ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onSelect(index) }
                                .padding(horizontal = 20.dp, vertical = 15.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                if (index == state.currentTrackIndex && state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = null,
                                tint = if (index == state.currentTrackIndex) CadenzaAccent else CadenzaTextTertiary,
                            )
                            Text(
                                "  ${index + 1}. $name",
                                color = if (index == state.currentTrackIndex) CadenzaAccent else CadenzaTextPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        HorizontalDivider(color = CadenzaDivider.copy(alpha = 0.6f))
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadSheet(state: CadenzaUiState, viewModel: CadenzaViewModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = CadenzaBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("MP3 받기", color = CadenzaTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "닫기", tint = CadenzaTextSecondary) }
            }
            Text("개인 Tailscale 변환 서버를 사용합니다.", color = CadenzaTextSecondary, fontSize = 13.sp)
            OutlinedTextField(
                value = state.serverUrl,
                onValueChange = viewModel::setServerUrl,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("개인 변환 서버 HTTPS 주소") },
                placeholder = { Text("https://mac-mini.example.ts.net") },
                singleLine = true,
                colors = cadenzaTextFieldColors(),
            )
            OutlinedTextField(
                value = state.videoUrl,
                onValueChange = viewModel::setVideoUrl,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("YouTube URL") },
                singleLine = true,
                colors = cadenzaTextFieldColors(),
            )
            Button(
                onClick = viewModel::downloadMp3,
                enabled = !state.isDownloading,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = CadenzaAccent, contentColor = CadenzaBackground),
            ) {
                if (state.isDownloading) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = CadenzaBackground)
                    Text("  ${downloadLabel(state.downloadStatus, state.downloadProgress)}")
                } else {
                    Text("MP3 받기", fontWeight = FontWeight.Bold)
                }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .statusBarsPadding()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .background(CadenzaSecondary, RoundedCornerShape(8.dp))
            .border(1.dp, CadenzaWarning, RoundedCornerShape(8.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(message, modifier = Modifier.weight(1f), color = CadenzaTextPrimary, fontSize = 13.sp)
        TextButton(onClick = onDismiss) { Text("닫기", color = CadenzaWarning) }
    }
}

@Composable
private fun QuickButton(title: String, emphasized: Boolean = false, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.background(if (emphasized) CadenzaAccent else CadenzaSecondary, CircleShape),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(title, color = if (emphasized) CadenzaBackground else CadenzaTextPrimary, fontSize = 13.sp)
    }
}

@Composable
private fun Timecode(milliseconds: Long, color: Color) {
    Text(formatTime(milliseconds), color = color, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
}

@Composable
private fun CadenzaRule() = HorizontalDivider(color = CadenzaDivider, thickness = 1.dp)

@Composable
private fun cadenzaSliderColors() = SliderDefaults.colors(
    thumbColor = CadenzaTextPrimary,
    activeTrackColor = CadenzaAccent,
    inactiveTrackColor = CadenzaSecondary,
    activeTickColor = Color.Transparent,
    inactiveTickColor = Color.Transparent,
)

@Composable
private fun CadenzaSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int = 0,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    val colors = cadenzaSliderColors()
    val interactionSource = remember { MutableInteractionSource() }
    Slider(
        value = value,
        onValueChange = onValueChange,
        valueRange = valueRange,
        steps = steps,
        onValueChangeFinished = onValueChangeFinished,
        colors = colors,
        interactionSource = interactionSource,
        modifier = Modifier.height(32.dp),
        thumb = {
            SliderDefaults.Thumb(
                interactionSource = interactionSource,
                colors = colors,
                thumbSize = DpSize(20.dp, 20.dp),
            )
        },
        track = { sliderState ->
            SliderDefaults.Track(
                sliderState = sliderState,
                modifier = Modifier.height(4.dp),
                colors = colors,
                drawStopIndicator = null,
                thumbTrackGapSize = 0.dp,
            )
        },
    )
}

@Composable
private fun cadenzaTextFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = CadenzaSecondary,
    unfocusedContainerColor = CadenzaSecondary,
    focusedTextColor = CadenzaTextPrimary,
    unfocusedTextColor = CadenzaTextPrimary,
    focusedIndicatorColor = CadenzaAccent,
    unfocusedIndicatorColor = CadenzaDivider,
    focusedLabelColor = CadenzaAccent,
    unfocusedLabelColor = CadenzaTextSecondary,
)

private fun downloadLabel(status: String?, progress: Int?): String = when (status) {
    "queued" -> "대기 중"
    "downloading" -> progress?.let { "변환 중 $it%" } ?: "변환 중"
    "ready" -> "완료"
    else -> "연결 중"
}

private fun bpmPillText(status: BpmStatus): String = when (status) {
    BpmStatus.METADATA -> "메타데이터"
    BpmStatus.DETECTED -> "자동 분석"
    BpmStatus.ANALYZING -> "분석 중"
    BpmStatus.MANUAL -> "직접 입력"
    BpmStatus.IDLE, BpmStatus.FAILED -> "확인 필요"
}

private fun bpmStatusLabel(status: BpmStatus): String = when (status) {
    BpmStatus.IDLE -> "확인 필요"
    BpmStatus.ANALYZING -> "분석 중"
    BpmStatus.METADATA -> "메타데이터"
    BpmStatus.DETECTED -> "자동 분석"
    BpmStatus.FAILED -> "입력 권장"
    BpmStatus.MANUAL -> "직접 입력"
}

private fun bpmStatusColor(status: BpmStatus): Color = when (status) {
    BpmStatus.METADATA, BpmStatus.DETECTED -> CadenzaAccent
    BpmStatus.IDLE, BpmStatus.FAILED -> CadenzaWarning
    else -> CadenzaTextSecondary
}

private fun bpmHelperText(status: BpmStatus): String = when (status) {
    BpmStatus.IDLE -> "메타데이터가 없어 120 BPM으로 가정했습니다. 정확한 속도를 위해 직접 입력하세요."
    BpmStatus.ANALYZING -> "원본 BPM을 분석하고 있습니다. 완료 전에는 1.00×로 재생합니다."
    BpmStatus.METADATA -> "파일의 BPM 메타데이터를 사용합니다."
    BpmStatus.DETECTED -> "오디오 신호에서 원본 BPM을 자동 분석했습니다."
    BpmStatus.FAILED -> "BPM을 확인하지 못했습니다. 정확한 속도를 위해 직접 입력하세요."
    BpmStatus.MANUAL -> "직접 입력한 원본 BPM을 사용합니다."
}

private fun formatTime(milliseconds: Long): String {
    val totalSeconds = (milliseconds.coerceAtLeast(0) / 1_000).toInt()
    return "%d:%02d".format(Locale.US, totalSeconds / 60, totalSeconds % 60)
}
