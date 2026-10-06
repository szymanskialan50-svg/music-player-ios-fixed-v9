# Music Player

A fast, minimal music player for iOS and Android with YouTube search,
a local library, playlists, vinyl now-playing screen, synced lyrics,
lock-screen controls, background playback and light / dark themes.

## Features

- Library from device files and YouTube; playlists, shuffle, repeat
- Background playback with lock-screen and Control Center controls
- Karaoke-style animated lyrics (LRCLIB / lyrics.ovh)
- Light, dark and system themes, custom accent color
- Languages: EN, PL, FR, ES, DE, IT

## Project layout

| Path | Purpose |
|---|---|
| `public/player.html` | the whole app UI and logic (copied to `www/index.html`) |
| `capacitor-youtube-player/` | native iOS plugin (playback, lock screen, background audio) |
| `YouTubePlayer/` | Swift YouTube player package |
| `.github/workflows/` | CI builds (see `MOBILE_BUILD.md`) |

## Build

```sh
npm install
npm run prepare:www   # copies public/player.html -> www/index.html
npx cap sync
```

Details for building the `.ipa` / `.apk`: see `MOBILE_BUILD.md`.
Set your own YouTube Data API key in `public/player.html` (`YOUTUBE_API_KEY`)
and restrict it to your bundle ID in Google Cloud Console.

## Legal

Copyright (c) 2026 x3lanix. All rights reserved — see `LICENSE`.
Third-party software, services and content: see `NOTICE.md` and `CREDITS.md`.
