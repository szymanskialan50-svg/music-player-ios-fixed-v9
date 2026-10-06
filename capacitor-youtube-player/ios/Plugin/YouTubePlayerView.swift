// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import SwiftUI
import WebKit

// MARK: - YouTubePlayerView

/// A SwiftUI view that displays a YouTube IFrame player managed by a `YouTubePlayer` controller.
///
/// Basic usage:
/// ```swift
/// @State private var player = YouTubePlayer()
///
/// var body: some View {
///     YouTubePlayerView(player: player)
///         .onAppear { player.load(videoId: "dQw4w9WgXcQ") }
/// }
/// ```
///
/// **Phase-based usage** — provide custom overlays for each phase:
/// ```swift
/// YouTubePlayerView(player: player) { phase in
///     switch phase {
///     case .loading:
///         ProgressView()
///     case .active:
///         EmptyView()
///     case .failed(let error):
///         ContentUnavailableView("Playback Error", systemImage: "exclamationmark.triangle")
///     }
/// }
/// ```
///
/// **Reacting to state changes** — use SwiftUI's `onChange` modifier:
/// ```swift
/// YouTubePlayerView(player: player) { phase in ... }
///     .onChange(of: player.playerState) { _, state in print(state) }
///     .onChange(of: player.playTime) { _, time in print(time) }
/// ```
public struct YouTubePlayerView<Overlay: View>: View {
    
    @ObservedObject var player: YouTubePlayer
    var overlay: (YouTubePlayerPhase) -> Overlay
    
    public var body: some View {
        ZStack {
            _YouTubeWebViewContainer(webView: player.webView)
            overlay(player.phase)
        }
        .background(Color.black)
    }
}

// MARK: - Initializers

extension YouTubePlayerView where Overlay == EmptyView {
    
    /// Creates a YouTube player view with no overlay.
    public init(player: YouTubePlayer) {
        self.player = player
        self.overlay = { _ in EmptyView() }
    }
}

// MARK: - Internal UIViewRepresentable

/// Hosts the `WKWebView` provided by the `YouTubePlayer` inside a plain `UIView` container.
///
/// Using a container `UIView` (rather than returning the `WKWebView` directly) lets
/// `updateUIView` safely swap the inner WKWebView if the player reloads with a new video.
private struct _YouTubeWebViewContainer: UIViewRepresentable {
    
    let webView: WKWebView?
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }
    
    func updateUIView(_ container: UIView, context: Context) {
        guard let webView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        // Only re-add when the WKWebView instance has changed
        if container.subviews.first !== webView {
            container.subviews.forEach { $0.removeFromSuperview() }
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
    }
}
