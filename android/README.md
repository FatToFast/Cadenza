# Cadenza for Android

Android cadence player for local or privately converted MP3 playback.

## Features

- Pick multiple MP3 files with Android's document picker and play them as a playlist.
- Restore the last playlist and current track after the app UI or process is recreated.
- Request an MP3 from the private Cadenza media server and save it under
  `Music/Cadenza` through Android's media library.
- Analyze the first 20 seconds of each selected track on-device to estimate BPM.
- Read ID3 `TBPM` metadata before audio analysis and persist successful metadata,
  analyzed, or manually entered BPM values across app restarts.
- Invalidate a saved BPM automatically when the selected file's size or modified
  time changes.
- Match the iPhone tempo plan: fold musical tempo without slowing down and drift
  the effective cadence by up to 10 SPM when that avoids an extreme speed-up.
- Preserve pitch while accelerating playback from 1.0x to 2.5x.
- Keep playback at 1.0x while BPM analysis runs; use manual BPM when analysis fails.
- Seek and move to the previous or next track from the app.
- Continue playback and control it from Android system media controls, the lock screen,
  Bluetooth devices, and headset buttons through a MediaSessionService.
- Set original BPM manually and persist the target cadence across app restarts.
- Optional metronome, off by default.
- Mirror the iPhone Player interface hierarchy, colors, cadence controls, playback
  controls, queue sheet, and MP3 actions while retaining Android system pickers.

## Build

Install JDK 17 and Android SDK 37, then:

```bash
cd android
./gradlew testDebugUnitTest assembleDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

The app accepts only an HTTPS server URL. Run `../media-server` behind Tailnet-only
Tailscale Serve rather than exposing it publicly.
