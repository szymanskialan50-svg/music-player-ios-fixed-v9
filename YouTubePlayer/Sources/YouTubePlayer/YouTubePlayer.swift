// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import WebKit
import UIKit
import Observation

// MARK: - YouTubePlayer

/// An observable controller that manages a YouTube IFrame player embedded in a WKWebView.
///
/// Create a `YouTubePlayer`, load a video or playlist, then display it with `YouTubePlayerView`.
///
/// ```swift
/// @State private var player = YouTubePlayer()
///
/// var body: some View {
///     YouTubePlayerView(player: player) { phase in
///         switch phase {
///         case .loading:  ProgressView()
///         case .active:   EmptyView()
///         case .failed:   ContentUnavailableView("Error", systemImage: "xmark.circle")
///         }
///     }
///     .onAppear { player.load(videoId: "dQw4w9WgXcQ") }
///     .onChange(of: player.playerState) { _, state in print(state) }
/// }
/// ```
@Observable
public final class YouTubePlayer: NSObject {
    
    // MARK: - Observable State
    
    /// The current playback state of the player.
    public private(set) var playerState: YouTubePlayerState = .unknown
    
    /// The current playback quality of the player.
    public private(set) var playbackQuality: YouTubePlaybackQuality = .unknown
    
    /// Whether the player is ready to accept API calls.
    public private(set) var isReady = false
    
    /// The underlying WKWebView. Becomes non-nil after the first `load` call.
    public private(set) var webView: WKWebView?
    
    /// The last error reported by the player, if any. Reset on each new `load` call.
    public private(set) var lastError: YouTubePlayerError?
    
    /// The current playback time in seconds, updated approximately twice per second.
    public private(set) var playTime: Float = 0
    
    /// The current phase of the player lifecycle.
    public var phase: YouTubePlayerPhase {
        if let lastError {
            return .failed(lastError)
        }
        if isReady {
            return .active(playerState)
        }
        return .loading
    }
    
    // MARK: - Private
    
    private var originURL: URL?
    
    // MARK: - Init
    
    public override init() {
        super.init()
    }
    
    // MARK: - Loading
    
    /// Loads a video by its YouTube video ID.
    ///
    /// - Parameters:
    ///   - videoId: The YouTube video ID (e.g. `"dQw4w9WgXcQ"`).
    ///   - playerVars: Optional IFrame player parameters.
    @discardableResult
    public func load(videoId: String, playerVars: YouTubePlayerVars = YouTubePlayerVars()) -> Bool {
        loadWithPlayerParams(["videoId": videoId, "playerVars": playerVars.toDictionary()])
    }
    
    /// Loads a playlist by its YouTube playlist ID.
    ///
    /// - Parameters:
    ///   - playlistId: The YouTube playlist ID.
    ///   - playerVars: Optional IFrame player parameters.
    @discardableResult
    public func load(playlistId: String, playerVars: YouTubePlayerVars = YouTubePlayerVars()) -> Bool {
        var vars = playerVars.toDictionary()
        vars["listType"] = "playlist"
        vars["list"] = playlistId
        return loadWithPlayerParams(["playerVars": vars])
    }
    
    /// Loads the player with a custom set of IFrame player parameters.
    ///
    /// Use this when you need full control over the player configuration.
    /// The `height`, `width`, and `events` keys are set automatically.
    ///
    /// - Parameter additionalPlayerParams: Extra player parameters to merge in.
    @discardableResult
    public func loadWithPlayerParams(_ additionalPlayerParams: [String: Any] = [:]) -> Bool {
        let playerCallbacks: [String: String] = [
            "onReady": "onReady",
            "onStateChange": "onStateChange",
            "onPlaybackQualityChange": "onPlaybackQualityChange",
            "onError": "onPlayerError"
        ]
        
        var playerParams = additionalPlayerParams
        if playerParams["height"] == nil { playerParams["height"] = "100%" }
        if playerParams["width"] == nil  { playerParams["width"]  = "100%" }
        playerParams["events"] = playerCallbacks
        
        var playerVars = (playerParams["playerVars"] as? [String: Any]) ?? [:]
        let origin = computeOriginURL()
        self.originURL = origin
        playerVars["origin"] = origin.absoluteString
        playerParams["playerVars"] = playerVars
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: playerParams, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let htmlTemplate = loadHTMLTemplate()
        else {
            return false
        }
        
        let embedHTML = htmlTemplate.replacingOccurrences(of: "%@", with: jsonString)
        
        let newWebView = makeWebView()
        self.webView = newWebView
        self.isReady = false
        self.playerState = .unknown
        self.playbackQuality = .unknown
        self.lastError = nil
        self.playTime = 0
        
        newWebView.loadHTMLString(embedHTML, baseURL: origin)
        return true
    }
    
    // MARK: - Playback Controls
    
    /// Starts or resumes playback.
    public func play() {
        evaluateJS("player.playVideo();")
    }
    
    /// Pauses playback.
    public func pause() {
        evaluateJS("player.pauseVideo();")
    }
    
    /// Stops playback and cancels video loading.
    public func stop() {
        evaluateJS("player.stopVideo();")
    }
    
    /// Seeks to a given time.
    ///
    /// - Parameters:
    ///   - seconds: The time in seconds to seek to.
    ///   - allowSeekAhead: When `true`, the player may make a new server request
    ///     if the desired time is beyond the buffered range.
    public func seekTo(_ seconds: Float, allowSeekAhead: Bool = true) {
        evaluateJS("player.seekTo(\(seconds), \(allowSeekAhead ? "true" : "false"));")
    }
    
    // MARK: - Cueing Videos
    
    /// Cues a video by ID without starting playback.
    public func cueVideoById(_ videoId: String, startSeconds: Float = 0) {
        evaluateJS("player.cueVideoById('\(videoId)', \(startSeconds));")
    }
    
    /// Cues a video by ID with start and end points, without starting playback.
    public func cueVideoById(_ videoId: String, startSeconds: Float, endSeconds: Float) {
        evaluateJS("player.cueVideoById({'videoId': '\(videoId)', 'startSeconds': \(startSeconds), 'endSeconds': \(endSeconds)});")
    }
    
    /// Loads and plays a video by ID, starting at the given time.
    public func loadVideoById(_ videoId: String, startSeconds: Float = 0) {
        evaluateJS("player.loadVideoById('\(videoId)', \(startSeconds));")
    }
    
    /// Loads and plays a video by ID with start and end points.
    public func loadVideoById(_ videoId: String, startSeconds: Float, endSeconds: Float) {
        evaluateJS("player.loadVideoById({'videoId': '\(videoId)', 'startSeconds': \(startSeconds), 'endSeconds': \(endSeconds)});")
    }
    
    /// Cues a video by its YouTube.com URL without starting playback.
    public func cueVideoByURL(_ videoURL: String, startSeconds: Float = 0) {
        evaluateJS("player.cueVideoByUrl('\(videoURL)', \(startSeconds));")
    }
    
    /// Cues a video by URL with start and end points, without starting playback.
    public func cueVideoByURL(_ videoURL: String, startSeconds: Float, endSeconds: Float) {
        evaluateJS("player.cueVideoByUrl('\(videoURL)', \(startSeconds), \(endSeconds));")
    }
    
    /// Loads and plays a video by its YouTube.com URL.
    public func loadVideoByURL(_ videoURL: String, startSeconds: Float = 0) {
        evaluateJS("player.loadVideoByUrl('\(videoURL)', \(startSeconds));")
    }
    
    /// Loads and plays a video by URL with start and end points.
    public func loadVideoByURL(_ videoURL: String, startSeconds: Float, endSeconds: Float) {
        evaluateJS("player.loadVideoByUrl('\(videoURL)', \(startSeconds), \(endSeconds));")
    }
    
    // MARK: - Playlist Cueing
    
    /// Cues a playlist by its YouTube playlist ID without starting playback.
    public func cuePlaylist(playlistId: String, index: Int = 0, startSeconds: Float = 0) {
        evaluateJS("player.cuePlaylist('\(playlistId)', \(index), \(startSeconds));")
    }
    
    /// Cues a playlist from an array of video IDs without starting playback.
    public func cuePlaylist(videoIds: [String], index: Int = 0, startSeconds: Float = 0) {
        let ids = videoIds.map { "'\($0)'" }.joined(separator: ", ")
        evaluateJS("player.cuePlaylist([\(ids)], \(index), \(startSeconds));")
    }
    
    /// Loads and plays a playlist by its YouTube playlist ID.
    public func loadPlaylist(playlistId: String, index: Int = 0, startSeconds: Float = 0) {
        evaluateJS("player.loadPlaylist('\(playlistId)', \(index), \(startSeconds));")
    }
    
    /// Loads and plays a playlist from an array of video IDs.
    public func loadPlaylist(videoIds: [String], index: Int = 0, startSeconds: Float = 0) {
        let ids = videoIds.map { "'\($0)'" }.joined(separator: ", ")
        evaluateJS("player.loadPlaylist([\(ids)], \(index), \(startSeconds));")
    }
    
    // MARK: - Playlist Navigation
    
    /// Loads and plays the next video in the playlist.
    public func nextVideo() {
        evaluateJS("player.nextVideo();")
    }
    
    /// Loads and plays the previous video in the playlist.
    public func previousVideo() {
        evaluateJS("player.previousVideo();")
    }
    
    /// Loads and plays the video at the given 0-indexed playlist position.
    public func playVideoAt(_ index: Int) {
        evaluateJS("player.playVideoAt(\(index));")
    }
    
    // MARK: - Playback Rate
    
    /// Sets the playback speed. Common values: 0.25, 0.5, 1.0, 1.5, 2.0.
    public func setPlaybackRate(_ rate: Float) {
        evaluateJS("player.setPlaybackRate(\(rate));")
    }
    
    /// Returns the current playback rate.
    public func playbackRate() async throws -> Float {
        let result = try await evaluateJSAsync("player.getPlaybackRate();")
        return (result as? NSNumber)?.floatValue ?? 1.0
    }
    
    /// Returns the list of playback rates supported for the current video.
    public func availablePlaybackRates() async throws -> [Float] {
        let result = try await evaluateJSAsync("player.getAvailablePlaybackRates();")
        guard let array = result as? [NSNumber] else { return [] }
        return array.map { $0.floatValue }
    }
    
    // MARK: - Playlist Settings
    
    /// Sets whether the playlist loops after the last video.
    public func setLoop(_ loop: Bool) {
        evaluateJS("player.setLoop(\(loop ? "true" : "false"));")
    }
    
    /// Sets whether the playlist plays in random order.
    public func setShuffle(_ shuffle: Bool) {
        evaluateJS("player.setShuffle(\(shuffle ? "true" : "false"));")
    }
    
    // MARK: - Playback Status Queries
    
    /// Returns the fraction of the video that has been buffered (0.0 – 1.0).
    public func videoLoadedFraction() async throws -> Float {
        let result = try await evaluateJSAsync("player.getVideoLoadedFraction();")
        return (result as? NSNumber)?.floatValue ?? 0
    }
    
    /// Returns the current elapsed time in seconds.
    public func currentTime() async throws -> Float {
        let result = try await evaluateJSAsync("player.getCurrentTime();")
        return (result as? NSNumber)?.floatValue ?? 0
    }
    
    /// Returns the current player state by querying JavaScript directly.
    public func getPlayerState() async throws -> YouTubePlayerState {
        let result = try await evaluateJSAsync("player.getPlayerState();")
        guard let number = result as? NSNumber else { return .unknown }
        return YouTubePlayerState(rawValue: number.intValue) ?? .unknown
    }
    
    // MARK: - Video Information Queries
    
    /// Returns the duration of the current video in seconds.
    public func duration() async throws -> Double {
        let result = try await evaluateJSAsync("player.getDuration();")
        return (result as? NSNumber)?.doubleValue ?? 0
    }
    
    /// Returns the YouTube.com URL of the current video.
    public func videoURL() async throws -> URL? {
        let result = try await evaluateJSAsync("player.getVideoUrl();")
        guard let string = result as? String else { return nil }
        return URL(string: string)
    }
    
    /// Returns the embed code for the current video.
    public func videoEmbedCode() async throws -> String? {
        let result = try await evaluateJSAsync("player.getVideoEmbedCode();")
        return result as? String
    }
    
    // MARK: - Playlist Information Queries
    
    /// Returns the video IDs in the current playlist.
    public func playlist() async throws -> [String] {
        let result = try await evaluateJSAsync("player.getPlaylist();")
        return (result as? [String]) ?? []
    }
    
    /// Returns the 0-indexed position of the currently playing video in the playlist.
    public func playlistIndex() async throws -> Int {
        let result = try await evaluateJSAsync("player.getPlaylistIndex();")
        return (result as? NSNumber)?.intValue ?? 0
    }
    
    // MARK: - Private Helpers
    
    private func computeOriginURL() -> URL {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.youtube.player"
        return URL(string: "http://\(bundleId.lowercased())")!
    }
    
    private func loadHTMLTemplate() -> String? {
        guard
            let path = Bundle.module.path(forResource: "YTPlayerView-iframe-player", ofType: "html"),
            let template = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return nil
        }
        return template
    }
    
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        return wv
    }
    
    private func evaluateJS(_ script: String) {
        webView?.evaluateJavaScript(script)
    }
    
    private func evaluateJSAsync(_ script: String) async throws -> Any? {
        guard let webView else { return nil }
        return try await webView.evaluateJavaScript(script)
    }
    
    // MARK: - Internal Callback Dispatch
    
    func handleCallback(action: String, data: String?) {
        switch action {
        case "onReady":
            isReady = true
            
        case "onStateChange":
            playerState = YouTubePlayerState(code: data ?? "")
            
        case "onPlaybackQualityChange":
            playbackQuality = YouTubePlaybackQuality(string: data ?? "")
            
        case "onError":
            lastError = YouTubePlayerError(code: data ?? "")
            
        case "onPlayTime":
            playTime = Float(data ?? "0") ?? 0
            
        case "onYouTubeIframeAPIFailedToLoad":
            lastError = .apiFailedToLoad
            
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension YouTubePlayer: WKNavigationDelegate {
    
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        
        // Intercept ytplayer:// callbacks from the IFrame API
        if url.scheme == "ytplayer" {
            let action = url.host ?? ""
            // Query format: "data=VALUE" — preserve "=" inside values (e.g. base64)
            let data: String? = url.query.flatMap {
                let parts = $0.components(separatedBy: "=")
                guard parts.count >= 2 else { return nil }
                let value = parts.dropFirst().joined(separator: "=")
                return value.isEmpty ? nil : value
            }
            handleCallback(action: action, data: data)
            return .cancel
        }
        
        if url.scheme == "http" || url.scheme == "https" {
            // Always allow navigations back to our base origin
            if let host = url.host?.lowercased(),
               host == originURL?.host?.lowercased() {
                return .allow
            }
            
            let urlString = url.absoluteString
            let allowedPatterns = [
                "^http(s)?://(www\\.)?youtube\\.com/embed/",
                "^http(s)?://pubads\\.g\\.doubleclick\\.net/",
                "^http(s)?://accounts\\.google\\.com/o/oauth2/",
                "^https://content\\.googleapis\\.com/static/proxy\\.html",
                "^https://tpc\\.googlesyndication\\.com/sodar/.*\\.html$"
            ]
            
            let isAllowed = allowedPatterns.contains {
                urlString.range(of: $0, options: .regularExpression) != nil
            }
            
            if !isAllowed {
                openURL(url)
                return .cancel
            }
            return .allow
        }
        
        return .allow
    }
    
    private func openURL(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

// MARK: - WKUIDelegate

extension YouTubePlayer: WKUIDelegate {
    
    /// Opens links that target a new window (e.g. YouTube logo tap) in the system browser.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            openURL(url)
        }
        return nil
    }
}
