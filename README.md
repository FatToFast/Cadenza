# Cadenza

A cadence-focused music companion for iOS and Android. It plays local music at
an adjustable tempo while keeping an optional metronome aligned to the target
cadence.

## Features

- Apple Music library playback with tempo adjustment
- Sample-accurate metronome synchronized to the detected beat
- Automatic BPM detection for imported tracks
- Lock screen and Now Playing remote control support
- Android MP3 playback with a private Tailnet-only conversion server

## Requirements

- iOS 17.0 or later
- Apple Music subscription (for streaming library tracks)

## Android

The Android MVP lives in [`android/`](android/) and uses local MP3 files instead
of Apple Music. A private `yt-dlp` conversion backend lives in
[`media-server/`](media-server/). Keep that backend on localhost and expose it
only with Tailscale Serve.

## Acknowledgements

BPM data provided by [GetSongBPM.com](https://getsongbpm.com).
