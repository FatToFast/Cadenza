# Cadenza Media Server

Private MP3 conversion backend for the Android Cadenza app. It binds to
`127.0.0.1` and invokes `yt-dlp` with an argument array, not through a shell.

## Requirements

```bash
brew install yt-dlp ffmpeg deno
```

## Run and expose only to your Tailnet

```bash
cd media-server
npm test
npm start

# In another terminal
tailscale serve --bg http://127.0.0.1:8899
```

Enter the resulting `https://<device>.<tailnet>.ts.net` URL in the Android app.
Do not enable Tailscale Funnel. Jobs are limited to a single video, 30 minutes,
and 250 MB; generated files older than 24 hours are removed both at startup and
while the server remains running.

Optional environment variables:

- `CADENZA_MEDIA_PORT` (default `8899`)
- `CADENZA_MEDIA_DIR`
- `CADENZA_YTDLP`
