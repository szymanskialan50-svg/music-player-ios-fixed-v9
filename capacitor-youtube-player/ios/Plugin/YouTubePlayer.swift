// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import WebKit
import UIKit
import Combine

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
public final class YouTubePlayer: NSObject, ObservableObject {
    
    // MARK: - Observable State
    
    /// The current playback state of the player.
    @Published public private(set) var playerState: YouTubePlayerState = .unknown
    
    /// The current playback quality of the player.
    @Published public private(set) var playbackQuality: YouTubePlaybackQuality = .unknown
    
    /// Whether the player is ready to accept API calls.
    @Published public private(set) var isReady = false
    
    /// The underlying WKWebView. Becomes non-nil after the first `load` call.
    @Published public private(set) var webView: WKWebView?
    
    /// The last error reported by the player, if any. Reset on each new `load` call.
    @Published public private(set) var lastError: YouTubePlayerError?
    
    /// The current playback time in seconds, updated approximately twice per second.
    @Published public private(set) var playTime: Float = 0
    
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
    
    /// A video that was requested via `load(videoId:)` while the webview's YouTube
    /// page was still starting up. Fired off as soon as `onReady` arrives instead
    /// of spinning up a second `WKWebView`.
    private var pendingVideoId: String?

    /// The video that is (or should be) loaded right now - used to recover when the
    /// web view dies or the YouTube page never becomes ready.
    private var currentVideoId: String?
    private var readyWatchdog: DispatchWorkItem?
    private var rebuildAttempts = 0

    /// Called whenever a brand-new WKWebView replaced the old one, so the owner
    /// can re-attach it to the window (a detached web view gets its media suspended).
    public var onWebViewReplaced: (() -> Void)?

    /// Commands coming from the web page's own media session (lock screen buttons that WebKit routes
    /// to the page) - the plugin handles them exactly like its own remote commands.
    public var onRemoteMessage: (([String: Any]) -> Void)?

    /// Sends a message to the page (and the YouTube iframe inside it).
    public func broadcast(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateJS("window.__mpBroadcast&&window.__mpBroadcast(\(json));")
    }

    fileprivate func handleScriptMessage(_ body: Any) {
        guard let d = body as? [String: Any] else { return }
        if (d["cmd"] as? String) == "yt" {
            let action = d["action"] as? String ?? ""
            let raw = d["data"] as? String
            handleCallback(action: action, data: (raw?.isEmpty ?? true) ? nil : raw)
        } else {
            onRemoteMessage?(d)
        }
    }
    
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
    ///
    /// BUGFIX: this used to call `loadWithPlayerParams` unconditionally, which tears
    /// down the current `WKWebView` and builds a brand-new one (reloading the whole
    /// YouTube IFrame page from scratch) for *every single track*. The old webview was
    /// never removed from the view hierarchy, so every song played left one more hidden
    /// `WKWebView` running behind the scenes — that's what was causing the lag every
    /// time a song "connected", the occasional need to tap play twice (the brand-new
    /// webview wasn't ready yet when `play()` was called right after), and the random
    /// crashes after listening for a while (memory pressure from the leaked webviews).
    /// Now the webview is created once and every subsequent track just asks the
    /// already-running IFrame player to switch videos, which is instant and leak-free.
    @discardableResult
    public func load(videoId rawVideoId: String, playerVars: YouTubePlayerVars = YouTubePlayerVars()) -> Bool {
        // YouTube ids are [A-Za-z0-9_-]; strip anything else so it can't break out of the JS string.
        let videoId = rawVideoId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        guard !videoId.isEmpty else { return false }
        currentVideoId = videoId
        rebuildAttempts = 0
        guard webView != nil else {
            // First-ever load: build the WKWebView + YouTube IFrame page once.
            return loadWithPlayerParams(["videoId": videoId, "playerVars": playerVars.toDictionary()])
        }
        guard isReady else {
            // The page is still starting up (e.g. this is the 2nd tap that landed
            // before the 1st video's page finished initializing) — remember the
            // latest request and let onReady dispatch it, instead of racing a
            // second webview into existence.
            pendingVideoId = videoId
            scheduleReadyWatchdog()
            return true
        }
        pendingVideoId = nil
        lastError = nil
        evaluateJS("window.setWant&&setWant(true);player.loadVideoById('\(videoId)', 0);")
        return true
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
        playerVars["autoplay"] = 1
        playerVars["playsinline"] = 1
        playerParams["playerVars"] = playerVars
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: playerParams, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let htmlTemplate = loadHTMLTemplate()
        else {
            return false
        }
        
        let embedHTML = htmlTemplate.replacingOccurrences(of: "%@", with: jsonString)
        
        if let old = self.webView {
            old.stopLoading()
            old.removeFromSuperview()
        }
        let newWebView = makeWebView()
        self.webView = newWebView
        self.isReady = false
        self.playerState = .unknown
        self.playbackQuality = .unknown
        self.lastError = nil
        self.playTime = 0
        
        newWebView.loadHTMLString(embedHTML, baseURL: origin)
        onWebViewReplaced?()
        scheduleReadyWatchdog()
        return true
    }

    // MARK: - Self-healing

    /// If the YouTube page never reports "ready" (no network at that moment, iframe API
    /// blocked, web process killed) every later tap would just queue up forever - that was
    /// the "song doesn't start, I have to tap again" bug. After 8 s we rebuild the page.
    private func scheduleReadyWatchdog() {
        readyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isReady, self.rebuildAttempts < 3,
                  let vid = self.pendingVideoId ?? self.currentVideoId else { return }
            self.rebuildAttempts += 1
            self.pendingVideoId = nil
            _ = self.loadWithPlayerParams(["videoId": vid, "playerVars": YouTubePlayerVars().toDictionary()])
        }
        readyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    
    // MARK: - Playback Controls
    
    /// Starts or resumes playback.
    public func play() {
        evaluateJS("window.setWant&&setWant(true);player.playVideo();")
    }
    
    /// Cheap, instant "if we should be playing but got paused behind our back, resume" - handled
    /// inside the page itself (no round-trip), used when the app changes state.
    public func nudge() {
        evaluateJS("window.nudgePlay&&nudgePlay();")
    }

    /// Pauses playback.
    public func pause() {
        evaluateJS("window.setWant&&setWant(false);player.pauseVideo();")
    }
    
    /// Stops playback and cancels video loading.
    public func stop() {
        evaluateJS("window.setWant&&setWant(false);player.stopVideo();")
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
        let bundle = Bundle(for: YouTubePlayer.self)
        guard
            let path = bundle.path(forResource: "YTPlayerView-iframe-player", ofType: "html"),
            let template = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return nil
        }
        return template
    }
    
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        /* Must be OFF: with Picture-in-Picture allowed, iOS tries to start PiP the moment the app
           is left while a video plays. That transition pauses the video for a split second -
           the tiny cut of the music when leaving the app. The audio keeps going without PiP. */
        if #available(iOS 14.0, *) {
            config.allowsPictureInPictureMediaPlayback = false
        }

        // Prevent YouTube from pausing video on visibility change
        let source = """
        Object.defineProperty(document, 'visibilityState', {
            get: function() { return 'visible'; }
        });
        Object.defineProperty(document, 'hidden', {
            get: function() { return false; }
        });
        document.addEventListener('visibilitychange', function(e) {
            e.stopImmediatePropagation();
        }, true);

        /* Lock screen / Dynamic Island.
           WebKit publishes the page's media session as "Now Playing" while the video plays - with no title and
           no picture (generic speaker icon). So the page must carry the REAL title / artist / cover (sent by the
           native plugin) and its buttons must do the real thing (forwarded to the plugin, which ignores the
           duplicate when its own command arrives too). */
        (function () {
            try {
                var ms = navigator.mediaSession;
                var st = { mode: 'skip', title: '', artist: '', art: '' };
                var realSet = (ms && ms.setActionHandler) ? ms.setActionHandler.bind(ms) : null;
                var mdDesc = ms ? Object.getOwnPropertyDescriptor(Object.getPrototypeOf(ms), 'metadata') : null;
                var post = function (cmd, val) { try { window.webkit.messageHandlers.mpRemote.postMessage({ cmd: cmd, val: val }); } catch (e) {} };
                var h = function (a, f) { if (!realSet) { return; } try { realSet(a, f); } catch (e) {} };
                var apply = function () {
                    if (!ms) { return; }
                    h('play', function () { post('play'); });
                    h('pause', function () { post('pause'); });
                    h('stop', function () { post('pause'); });
                    h('seekto', function (d) { if (d && typeof d.seekTime === 'number') { post('seek', d.seekTime); } });
                    if (st.mode === 'skip') {
                        h('seekforward', function () { post('skip', 10); });
                        h('seekbackward', function () { post('skip', -10); });
                        h('nexttrack', null); h('previoustrack', null);
                    } else {
                        h('nexttrack', function () { post('next'); });
                        h('previoustrack', function () { post('previous'); });
                        h('seekforward', null); h('seekbackward', null);
                    }
                    if (st.title && mdDesc && mdDesc.set && window.MediaMetadata) {
                        try {
                            mdDesc.set.call(ms, new MediaMetadata({
                                title: st.title, artist: st.artist, album: 'Music Player',
                                artwork: st.art ? [{ src: st.art, sizes: '512x512', type: 'image/jpeg' }] : []
                            }));
                        } catch (e) {}
                    }
                };
                if (ms) {
                    /* the YouTube page must not replace our handlers / metadata with its own */
                    ms.setActionHandler = function () {};
                    try { Object.defineProperty(ms, 'metadata', { get: function () { return null; }, set: function () {}, configurable: true }); } catch (e) {}
                }
                var onMsg = function (d) {
                    if (!d || !d.mp) { return; }
                    if (d.mp === 'meta') { st.title = d.title || ''; st.artist = d.artist || ''; st.art = d.art || ''; }
                    else if (d.mp === 'mode') { st.mode = d.mode === 'tracks' ? 'tracks' : 'skip'; }
                    else if (d.mp === 'hold') { window.__mpHold = !!d.on; return; }
                    apply();
                };
                window.addEventListener('message', function (e) { onMsg(e.data); });
                window.__mpBroadcast = function (d) {
                    onMsg(d);
                    var fr = document.getElementsByTagName('iframe');
                    for (var i = 0; i < fr.length; i++) { try { fr[i].contentWindow.postMessage(d, '*'); } catch (e) {} }
                };
                apply();
            } catch (e) {}
        })();

        /* When WebKit pauses the video behind our back (leaving the app, route change ...) start it again
           IMMEDIATELY from the pause event instead of waiting for the next poll - makes the gap
           inaudible. A pause that came from a real .pause() call (user / lock screen / app) is respected. */
        (function () {
            try {
                var P = HTMLMediaElement.prototype, op = P.pause, opl = P.play, recent = [];
                P.pause = function () { this.__mpPause = Date.now(); this.__mpWant = false; return op.apply(this, arguments); };
                P.play = function () { this.__mpWant = true; return opl.apply(this, arguments); };
                document.addEventListener('pause', function (e) {
                    var v = e.target;
                    if (!v || !v.__mpWant || v.ended || window.__mpHold) { return; }
                    var now = Date.now();
                    if (now - (v.__mpPause || 0) < 400) { return; }
                    recent = recent.filter(function (t) { return now - t < 5000; });
                    if (recent.length >= 6) { return; }
                    recent.push(now);
                    try { var pr = opl.call(v); if (pr && pr.catch) { pr.catch(function () {}); } } catch (e2) {}
                }, true);
            } catch (e) {}
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(WeakScriptHandler(self), name: "mpRemote")
        
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        return wv
    }
    
    private func evaluateJS(_ script: String) {
        if Thread.isMainThread { webView?.evaluateJavaScript(script, completionHandler: nil) }
        else { DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(script, completionHandler: nil) } }
    }
    
    /// WKWebView may only be used from the main thread, and the async variant of evaluateJavaScript
    /// crashes when the script returns nothing. Both were happening (the state timer runs off-main) -
    /// this version hops to main and tolerates nil.
    private func evaluateJSAsync(_ script: String) async throws -> Any? {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            DispatchQueue.main.async { [weak self] in
                guard let wv = self?.webView else { cont.resume(returning: nil); return }
                wv.evaluateJavaScript(script) { result, error in
                    if let error = error { cont.resume(throwing: error) } else { cont.resume(returning: result) }
                }
            }
        }
    }
    
    // MARK: - Internal Callback Dispatch
    
    func handleCallback(action: String, data: String?) {
        switch action {
        case "onReady":
            isReady = true
            rebuildAttempts = 0
            readyWatchdog?.cancel()
            if let pending = pendingVideoId {
                pendingVideoId = nil
                evaluateJS("window.setWant&&setWant(true);player.loadVideoById('\(pending)', 0);")
            } else {
                play()
            }
            
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

    /// iOS may kill the web content process (memory pressure, long background time).
    /// The player would then stay dead and every tap would do nothing - rebuild it and
    /// continue the same video from about where it stopped.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let vid = currentVideoId else { return }
        isReady = false
        let resumeAt = Int(max(0, playTime))
        pendingVideoId = nil
        _ = loadWithPlayerParams(["videoId": vid, "playerVars": ["start": resumeAt]])
    }
    
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


/// WKUserContentController retains its handlers - go through a weak proxy so the player can be freed.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: YouTubePlayer?
    init(_ target: YouTubePlayer) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleScriptMessage(message.body)
    }
}
