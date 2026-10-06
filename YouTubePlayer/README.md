# YouTubePlayer

A modern Swift rewrite of the official [youtube-ios-player-helper](https://github.com/youtube/youtube-ios-player-helper) library by Google. Built for SwiftUI with `@Observable`, async/await, and a type-safe API — no Objective-C, no delegates, no CocoaPods required.

## Origin

This package is a ground-up Swift conversion of `youtube-ios-player-helper`, the original Objective-C library maintained by Google. The core embedding approach (YouTube IFrame API via `WKWebView`) is the same, but the entire public API has been rewritten:

| Original (`youtube-ios-player-helper`) | This package (`YouTubePlayer`) |
|---|---|
| Objective-C, UIKit only | Swift 6, SwiftUI-first |
| `YTPlayerView` + `YTPlayerViewDelegate` | `YouTubePlayerView` + `@Observable YouTubePlayer` |
| `[String: Any]` player vars | `YouTubePlayerVars` struct (type-safe) |
| CocoaPods / manual install | Swift Package Manager |
| Callback delegate pattern | Phase-based API (like `AsyncImage`) + `onChange` |

## Requirements

- iOS 17+
- Swift 6.2+
- Xcode 16+

## Installation

### Swift Package Manager

Add the package in Xcode via **File → Add Package Dependencies**, or add it manually to your `Package.swift`:

```swift
    .package(url: "https://github.com/OpenSwiftXO/YouTubePlayer", from: "1.1.0")
```

Then add `YouTubePlayer` to your target's dependencies:

```swift
    .target(name: "YourApp", dependencies: ["YouTubePlayer"])
```

## Usage

### Basic

```swift
    import SwiftUI
    import YouTubePlayer
    
    struct ContentView: View {
    @State private var player = YouTubePlayer()
    
    var body: some View {
        YouTubePlayerView(player: player)
        .onAppear {
            player.load(videoId: "dQw4w9WgXcQ")
        }
    }
```

### With player parameters

```swift
    player.load(
        videoId: "dQw4w9WgXcQ",
        playerVars: YouTubePlayerVars(
            autoplay: true,
            playsInline: true,
            controls: false,
            start: 30
        )
    )
```

### Phase-based overlays

`YouTubePlayerView` follows the same pattern as SwiftUI's `AsyncImage`. Provide a closure that receives the current `YouTubePlayerPhase` and return an overlay for each phase:

```swift
    YouTubePlayerView(player: player) { phase in
        switch phase {
            case .loading:
            ProgressView()
            case .active(let state):
            // state is YouTubePlayerState: .playing, .paused, .ended, ...
            EmptyView()
            case .failed(let error):
            // error is YouTubePlayerError: .videoNotFound, .notEmbeddable, ...
            ContentUnavailableView("Playback Error", systemImage: "exclamationmark.triangle", description: Text("\(error)"))
        }
    }
```

### Reacting to state changes

Use SwiftUI's `onChange` modifier to observe any `@Observable` property on the player:

```swift
    YouTubePlayerView(player: player) { phase in
        // ...
    }
    .onChange(of: player.playerState) { _, state in
        print("State changed: \(state)")
    }
    .onChange(of: player.playTime) { _, time in
        print("Current time: \(time)s")
    }
    .onChange(of: player.playbackQuality) { _, quality in
        print("Quality: \(quality)")
    }
```

### Observable properties

| Property | Type | Description |
|---|---|---|
| `phase` | `YouTubePlayerPhase` | `.loading`, `.active(state)`, or `.failed(error)` |
| `isReady` | `Bool` | Whether the player is ready to accept API calls |
| `playerState` | `YouTubePlayerState` | `.playing`, `.paused`, `.ended`, `.buffering`, etc. |
| `playbackQuality` | `YouTubePlaybackQuality` | `.auto`, `.hd720`, `.hd1080`, etc. |
| `playTime` | `Float` | Current playback time in seconds (updated ~2×/sec) |
| `lastError` | `YouTubePlayerError?` | Last error, if any (reset on each `load`) |

### Playback controls

```swift
    player.play()
    player.pause()
    player.stop()
    player.seekTo(120, allowSeekAhead: true)
    player.setPlaybackRate(1.5)
```

### Querying state

```swift
    let duration = try await player.duration()
    let currentTime = try await player.currentTime()
    let buffered = try await player.videoLoadedFraction()
    let rate = try await player.playbackRate()
```

### Loading a playlist

```swift
    player.load(
        playlistId: "PLbpi6ZahtOH6Ar_3GPy3workRCNnrOaBk",
        playerVars: YouTubePlayerVars(
            autoplay: true,
            loop: true
        )
    )
```

## `YouTubePlayerVars` reference

All properties are optional. Omit any property to use the YouTube player's default.

| Property | Description |
|---|---|
| `autoplay` | Start playing automatically when loaded |
| `start` | Start offset in seconds |
| `end` | Stop offset in seconds |
| `loop` | Loop video/playlist indefinitely |
| `controls` | Show the player control bar |
| `fullscreen` | Show the fullscreen button |
| `relatedVideos` | Show related videos from any channel at end (`true`) or same channel only (`false`) |
| `progressBarColor` | `.red` (default) or `.white` |
| `keyboardControls` | Allow keyboard shortcuts |
| `playsInline` | Play inline on iPhone instead of going full-screen |
| `annotations` | Show video annotations |
| `captionLanguage` | Default caption language (BCP-47, e.g. `"en"`, `"vi"`) |
| `showCaptions` | Always show captions |
| `language` | Player UI language (BCP-47) |

## Original library

Original authors of `youtube-ios-player-helper`:
- Ikai Lan
- Ibrahim Ulukaya
- Yoshifumi Yamaguchi

## License

Available under the Apache 2.0 license. See the LICENSE file for more info.
