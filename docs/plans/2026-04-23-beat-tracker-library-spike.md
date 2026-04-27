# Beat Tracker Library Spike

**Goal:** Decide whether Cadenza should keep improving its built-in `BeatAlignmentAnalyzer` or benchmark an external beat tracker before implementing automatic Apple Music beat sync.

**Current constraint:** Apple Music `ApplicationMusicPlayer` exposes playback control and playback time, but not decoded PCM samples. External beat trackers can only analyze audio that Cadenza can actually decode: local files, non-protected library assets, MusicKit preview assets, or iTunes preview URLs.

---

## Findings

- Apple Music catalog playback should not be treated as an analyzable audio stream.
  - Use `ApplicationMusicPlayer` for playback state and transport only.
  - Use preview assets or metadata lookups for analysis.
  - If no preview/asset URL is available, fall back to BPM-only behavior.

- The existing Cadenza analyzer already has the right app-level shape.
  - It returns BPM, beat offset, confidence, and beat timestamps.
  - The missing piece is not another manual nudge control; it is reliability gating and better benchmark data.

- The repo currently has one bundled audio sample:
  - `Cadenza/Resources/Kickdrum Rocket-2.mp3`
  - MP3, 48 kHz stereo, about 178 seconds.
  - This is not enough to judge beat tracker quality across Apple Music-style tracks.

## Candidate Libraries

| Candidate | Fit | Risk | Decision |
| --- | --- | --- | --- |
| aubio | Mature tempo/beat detection; iOS builds exist | GPLv3 licensing is a likely App Store/product blocker | Use only as local benchmark if needed |
| BTrack | Real-time C++ beat tracker | GPLv3 licensing; weaker downbeat/general-song story than newer ML models | Do not embed |
| Essentia | Produces BPM, beat positions, and confidence; strong MIR toolkit | Heavy iOS integration; model/license constraints for commercial use | Useful reference, not first app dependency |
| Beat This | Modern ML beat/downbeat tracker; MIT source; small model option exists | Python/PyTorch path is not app-ready; ONNX/iOS feasibility unproven | Best benchmark candidate |

## Recommended Spike

### Step 1: Build a benchmark set

- Collect 20 short tracks or preview URLs:
  - 5 clear EDM/pop tracks.
  - 5 K-pop or dance tracks with strong percussion.
  - 5 vocal-heavy/soft-intro tracks.
  - 5 half-time/double-time ambiguous tracks.
- Store only metadata and source URLs in repo; do not commit copyrighted audio.
- For local testing, download previews into a temp/cache directory outside git.

### Step 2: Benchmark current analyzer

- Add a temporary CLI or XCTest-only harness that runs `BeatAlignmentAnalyzer.loadOrAnalyze`.
- Output JSON/CSV fields:
  - title, artist, expected BPM if known;
  - estimated BPM;
  - beat offset;
  - beat count;
  - confidence;
  - beat interval variation;
  - classification: automatic beat sync, BPM-only, needs confirmation, unstable beat grid.
- Keep the harness out of production UI.

### Step 3: Benchmark Beat This externally

- Run Beat This as a development-only Python/CLI tool against the same downloaded previews.
- Compare:
  - BPM agreement;
  - first 8 beat timestamps;
  - downbeat availability;
  - false half/double-time rate;
  - runtime on Apple Silicon CPU.
- Do not integrate PyTorch into the iOS app.

### Step 4: Decide app integration path

- If Cadenza's analyzer is close enough after reliability gating, keep it and avoid a dependency.
- If Beat This is materially better, run a second spike for ONNX Runtime iOS using the small model.
- If iOS ONNX is too heavy, keep Beat This as an offline benchmark only and improve the built-in analyzer using its outputs as reference.

## Acceptance Criteria

- At least 20 benchmark entries are tested.
- Current analyzer and Beat This produce comparable beat timestamp reports.
- We can clearly classify each track into:
  - `자동 박자 맞춤`
  - `BPM만 맞춤`
  - `확인 필요`
  - `박자 불안정`
- No GPL/AGPL dependency is embedded in the app target.
- No copyrighted full audio file is committed.

## Sources

- Apple MusicPlayer documentation: https://developer.apple.com/documentation/musickit/musicplayer
- Apple MPMediaItem documentation: https://developer.apple.com/documentation/mediaplayer/mpmediaitem
- aubio: https://github.com/aubio/aubio
- BTrack: https://github.com/adamstark/BTrack
- Essentia beat detection documentation: https://essentia.upf.edu/tutorial_rhythm_beatdetection.html
- Essentia licensing notes: https://essentia.upf.edu/licensing_information.html
- Beat This: https://github.com/CPJKU/beat_this
- Beat This C++/ONNX port: https://github.com/mosynthkey/beat_this_cpp
