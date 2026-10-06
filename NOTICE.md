# Third-Party Notices

Music Player, Copyright (c) 2026 x3lanix. All rights reserved (see `LICENSE`).

This product includes or uses the following third-party software and services.
All trademarks and content belong to their respective owners.

## Included components

| Component | Author / owner | License | Where |
|---|---|---|---|
| **YouTubePlayer** (Swift) — a Swift rewrite based on *youtube-ios-player-helper* | derived from the work of Google Inc. / YouTube | Apache License 2.0 | `YouTubePlayer/`, `capacitor-youtube-player/ios/Plugin/` (full text: `YouTubePlayer/LICENSE`) |
| **Capacitor** (`@capacitor/core`, `/ios`, `/android`) | Ionic / Drifty Co. | MIT | npm dependency |

The files under `YouTubePlayer/` and `capacitor-youtube-player/ios/Plugin/`
were modified for this project (background playback, native queue hand-off,
lock-screen controls, performance). The Apache 2.0 license text and the
original attribution are kept in `YouTubePlayer/LICENSE`.

## Online services used at run time

| Service | Owner | Used for | Terms |
|---|---|---|---|
| YouTube IFrame Player API, YouTube Data API v3 | Google LLC | audio playback and search | https://www.youtube.com/t/terms · https://developers.google.com/youtube/terms/api-services-terms-of-service |
| LRCLIB (lrclib.net) | LRCLIB contributors | song lyrics and timestamps | https://lrclib.net |
| lyrics.ovh | lyrics.ovh | fallback plain-text lyrics | https://lyrics.ovh |

Song lyrics, music, video, thumbnails and artwork shown in the app belong to
their respective authors, labels and publishers. Music Player does not host
or redistribute them.

YouTube is a trademark of Google LLC. Music Player is not affiliated with,
endorsed by or sponsored by Google, YouTube, Apple or any other company named
here.
