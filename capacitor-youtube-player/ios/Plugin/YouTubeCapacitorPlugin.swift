// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import Foundation
import Capacitor
import WebKit
import AVFoundation
import MediaPlayer
import UIKit

@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {

    private var player: YouTubePlayer?
    private var timer: Timer?
    private var intendedPlaybackState = "paused"
    private let silentPlayer = SilentAudioPlayer()
    private var didNotifyErrorForCurrentLoad = false
    /// Only tell JS about *changes* of the player state (it used to get the same
    /// state 10x per second, each time re-rendering the whole track list = lag).
    private var lastNotifiedState = ""
    private var cachedDuration: Double = 0
    private var lastDurationFetch = Date.distantPast

    /// true while the system (phone call, Siri, another app) owns the audio session.
    /// During that time we must NOT fight the system by force-resuming.
    private var isInterrupted = false
    private var lastResumeAttempt = Date.distantPast
    private var lastNowPlayingUpdate = Date.distantPast
    private var loadStartedAt = Date.distantPast

    /// true while a LOCAL file (played by the web view's <audio>) is the current track.
    /// Then the web side owns the lock screen and every native handler stays out of the way,
    /// otherwise both would react to the same button press (double skip, wrong play/pause icon).
    private var localMode = false
    /// true: lock screen shows -10 s / +10 s buttons; false: previous / next track buttons.
    private var lockSkipMode = true

    /// While paused we keep the (silent) audio engine alive for a while. If the app has
    /// no audio at all, iOS suspends it and drops the lock-screen player -> it turned into
    /// a bare app icon and "play" from the lock screen did nothing.
    private var silenceStopWork: DispatchWorkItem?

    // Now Playing (lock screen / Control Center) state
    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?
    /// URL the current artwork belongs to (so a slow download of the PREVIOUS song can never overwrite it)
    private var npArtKey = ""
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    /// same cover as a small JPEG data: URL - handed to the web page's media session (see broadcastWebSession)
    private var artDataCache: [String: String] = [:]
    private var npArtDataUrl: String?

    /// Every resume burst gets a number; a pause / newer play cancels all older bursts
    /// (tapping play/pause quickly used to leave dozens of stale "play" timers behind).
    private var resumeGeneration = 0
    private var lastToggleAt = Date.distantPast
    private var remoteGateTimes: [String: Date] = [:]
    private var stateQueryInFlight = false
    private var npDuration: Double = 0
    private var npElapsed: Double = 0
    private var remoteCommandsConfigured = false

    // Native auto-advance: JS hands us the upcoming YouTube tracks so the next
    // song starts even when iOS has suspended the main web view in background.
    private struct UpNextItem {
        let videoId: String; let index: Int
        let title: String; let artist: String
        let duration: Double; let artworkUrl: String?
    }
    private var upNext: [UpNextItem] = []
    private var repeatOne = false
    private var didHandleEndForCurrentLoad = false
    /// last song the native side started on its own (JS is told again when the app comes back)
    private var lastAdvanced: (index: Int, videoId: String)?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Lifecycle

    public override func load() {
        super.load()
        DispatchQueue.main.async {
            self.activateAudioSession(force: true)
            self.silentPlayer.play() // keeps the process "audible" so iOS doesn't suspend it
            UIApplication.shared.beginReceivingRemoteControlEvents()

            // Page-Visibility spoof for the main Capacitor WebView.
            if let webView = self.bridge?.webView {
                let source = """
                Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; } });
                Object.defineProperty(document, 'hidden', { get: function() { return false; } });
                document.addEventListener('visibilitychange', function(e) { e.stopImmediatePropagation(); }, true);
                """
                let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                webView.configuration.userContentController.addUserScript(script)
            }

            self.player = YouTubePlayer()
            self.player?.onWebViewReplaced = { [weak self] in
                DispatchQueue.main.async { self?.attachPlayerWebViewIfNeeded() }
            }
            self.player?.onRemoteMessage = { [weak self] d in
                DispatchQueue.main.async { self?.handleWebRemote(d) }
            }
            self.setupRemoteCommands()

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: nil)
            nc.addObserver(self, selector: #selector(self.routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        }
    }

    /// Only touches the audio session when something actually has to change. Re-applying the
    /// category / re-activating on every tick (it used to run ~4x per second) can make iOS
    /// re-route the output and was one source of the tiny dropout when leaving the app.
    private var sessionNeedsActivation = true

    private func activateAudioSession(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            if force || session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
                sessionNeedsActivation = true
            }
            if force || sessionNeedsActivation {
                try session.setActive(true)
                sessionNeedsActivation = false
            }
        } catch {
            print("Audio session error: \(error)")
        }
    }

    /// The YouTube web view must stay a real, non-hidden view inside the window.
    /// A `isHidden = true` WKWebView gets its media suspended by iOS the moment
    /// the app is backgrounded - that was the main cause of the music stopping.
    /// It sits *behind* the main web view, so the user never sees it.
    private func attachPlayerWebViewIfNeeded() {
        guard let wv = player?.webView, wv.superview == nil else { return }
        wv.isHidden = false
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        wv.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        if let main = bridge?.webView, let parent = main.superview {
            parent.insertSubview(wv, belowSubview: main)
        } else if let root = bridge?.viewController?.view {
            root.addSubview(wv)
        }
    }

    // MARK: - Background / interruption handling

    private func keepSessionAliveWhilePaused() {
        silenceStopWork?.cancel()
        activateAudioSession()
        silentPlayer.play()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.intendedPlaybackState != "playing" else { return }
            self.silentPlayer.pause()
        }
        silenceStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60, execute: work)
    }

    private func cancelSilenceStop() {
        silenceStopWork?.cancel()
        silenceStopWork = nil
    }

    private func performPlay() {
        isInterrupted = false
        intendedPlaybackState = "playing"
        cancelSilenceStop()
        pushNowPlaying()      // lock screen switches to "playing" immediately
        resumeIfIntended()    // plays now and re-tries a few times if WebKit is slow to wake up
    }

    private func performPause() {
        intendedPlaybackState = "paused"
        resumeGeneration &+= 1          // cancels every pending resume attempt
        player?.pause()
        keepSessionAliveWhilePaused()
        pushNowPlaying()
    }

    /// Resume playback right away and a few more times shortly after.
    /// WebKit pauses media for a split second when the app changes state
    /// (that was the 0.5s "stutter"); re-issuing play immediately - and again
    /// after short delays - makes the transition seamless, like Spotify.
    private func resumeIfIntended() {
        guard intendedPlaybackState == "playing", !isInterrupted else { return }
        activateAudioSession()
        silentPlayer.play()
        player?.play()
        player?.nudge()
        resumeGeneration &+= 1
        let gen = resumeGeneration
        for delay in [0.05, 0.15, 0.35, 0.7, 1.3, 2.5, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, gen == self.resumeGeneration,
                      self.intendedPlaybackState == "playing", !self.isInterrupted else { return }
                let st = self.player?.playerState
                if st != .playing && st != .buffering {
                    self.activateAudioSession()
                    self.silentPlayer.play()
                    self.player?.play()
                }
            }
        }
    }

    /// Extra grace period from iOS while we re-establish playback.
    private func beginResumeTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "music-resume") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
        }
    }

    @objc func appWillResignActive() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
            self.pushNowPlaying()
        }
    }
    @objc func appDidEnterBackground() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
            // Re-publish the Now Playing card right as we go to the background so the Dynamic Island /
            // lock screen picks the app up as the active media app.
            self.pushNowPlaying()
            if self.intendedPlaybackState == "playing" {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
        }
    }
    @objc func appDidBecomeActive() {
        DispatchQueue.main.async {
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            // JS may have been frozen while we changed state (e.g. paused from the lock screen):
            // forget what we told it last so the next tick re-sends the real state.
            self.lastNotifiedState = ""
            self.resumeIfIntended()
            self.pushNowPlaying()
            self.broadcastWebSession()
            // The web view may have been frozen while we advanced to the next song on our own:
            // tell it again which song is really playing, so title / lyrics / queue never lag behind.
            if let a = self.lastAdvanced {
                self.notifyListeners("youtubeAdvanced", data: ["index": a.index, "videoId": a.videoId])
            }
        }
    }
    @objc func engineConfigChanged() {
        // Only recover when the system really stopped our engine - restarting a running one makes iOS
        // re-route the output, which is audible as a short dropout of the music.
        DispatchQueue.main.async { if self.intendedPlaybackState == "playing" { self.silentPlayer.recoverIfNeeded() } }
    }
    @objc func mediaServicesReset() {
        DispatchQueue.main.async {
            self.sessionNeedsActivation = true
            self.activateAudioSession(force: true)
            self.silentPlayer.restart()
            self.resumeIfIntended()
        }
    }

    @objc func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones unplugged -> iOS convention is to pause (like Spotify).
        // BUT only when the *previous* output really was headphones / Bluetooth / USB and the
        // new route has none. Other route changes (speaker <-> receiver, Bluetooth profile
        // switch, AirPlay hiccup) used to pause the music "by itself" right after starting a song.
        guard reason == .oldDeviceUnavailable else { return }
        let headsetPorts: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let previous = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let hadHeadset = previous?.outputs.contains(where: { headsetPorts.contains($0.portType) }) ?? false
        guard hadHeadset else { return }
        DispatchQueue.main.async {
            let stillHeadset = AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { headsetPorts.contains($0.portType) })
            if !stillHeadset && !self.localMode { self.performPause() }
        }
    }

    @objc func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.isInterrupted = true
                self.resumeGeneration &+= 1
                self.player?.broadcast(["mp": "hold", "on": true])
            } else {
                self.isInterrupted = false
                self.player?.broadcast(["mp": "hold", "on": false])
                self.sessionNeedsActivation = true
                let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resumeIfIntended()
                } else {
                    self.intendedPlaybackState = "paused"
                }
            }
        }
    }

    // MARK: - Lock screen / Control Center (Now Playing)

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remotePlay(); return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remotePause(); return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.localMode { return .success }
            if self.intendedPlaybackState == "playing" { self.remotePause() } else { self.remotePlay() }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteTrack("next"); return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteTrack("previous"); return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, !self.localMode else { return .success }
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player?.seekTo(Float(e.positionTime), allowSeekAhead: true)
            self.npElapsed = e.positionTime
            self.pushNowPlaying()
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.preferredIntervals = [10]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteSkip(10); return .success
        }
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteSkip(-10); return .success
        }
        applyLockScreenMode()
    }

    /// iOS shows either the +/-10 s buttons or previous/next track - enabling both hides the 10 s ones.
    private func applyLockScreenMode() {
        let cc = MPRemoteCommandCenter.shared()
        cc.skipForwardCommand.isEnabled = lockSkipMode
        cc.skipBackwardCommand.isEnabled = lockSkipMode
        cc.nextTrackCommand.isEnabled = !lockSkipMode
        cc.previousTrackCommand.isEnabled = !lockSkipMode
    }

    /// The same button can reach us twice (our own command center target AND the web page's media
    /// session). The second copy arrives within a few ms - drop it.
    private func remoteGate(_ key: String, window: TimeInterval = 0.2) -> Bool {
        let now = Date()
        if let t = remoteGateTimes[key], now.timeIntervalSince(t) < window { return false }
        remoteGateTimes[key] = now
        return true
    }

    private func remoteTrack(_ name: String) {
        DispatchQueue.main.async {
            guard self.remoteGate("track-" + name) else { return }
            self.notifyListeners("youtubeRemoteCommand", data: ["command": name])
        }
    }

    private func handleWebRemote(_ d: [String: Any]) {
        guard !localMode else { return }
        switch d["cmd"] as? String ?? "" {
        case "play": remotePlay()
        case "pause": remotePause()
        case "next": remoteTrack("next")
        case "previous": remoteTrack("previous")
        case "skip": remoteSkip((d["val"] as? NSNumber)?.doubleValue ?? 10)
        case "seek":
            if let t = (d["val"] as? NSNumber)?.doubleValue {
                player?.seekTo(Float(max(0, t)), allowSeekAhead: true)
                npElapsed = max(0, t); pushNowPlaying()
            }
        default: break
        }
    }

    /// Gives the web page's media session (which WebKit shows as "Now Playing" while the video plays)
    /// the same title / artist / cover / buttons as our own card - otherwise the Dynamic Island shows a
    /// generic speaker while playing and the real cover only while paused.
    private func broadcastWebSession() {
        guard !localMode, let p = player else { return }
        var meta: [String: Any] = ["mp": "meta", "title": npTitle, "artist": npArtist]
        if let a = npArtDataUrl { meta["art"] = a }
        p.broadcast(meta)
        p.broadcast(["mp": "mode", "mode": lockSkipMode ? "skip" : "tracks"])
    }

    private func remoteSkip(_ delta: Double) {
        DispatchQueue.main.async {
            guard self.remoteGate(delta > 0 ? "skip+" : "skip-") else { return }
            var target = self.npElapsed + delta
            if self.npDuration > 0 { target = min(target, max(0, self.npDuration - 1)) }
            target = max(0, target)
            self.player?.seekTo(Float(target), allowSeekAhead: true)
            self.npElapsed = target
            self.pushNowPlaying()
        }
    }

    @objc func setLockScreenMode(_ call: CAPPluginCall) {
        let mode = call.getString("mode") ?? "skip"
        DispatchQueue.main.async {
            self.lockSkipMode = (mode != "tracks")
            self.applyLockScreenMode()
            self.broadcastWebSession()
            call.resolve()
        }
    }

    private func remotePlay() {
        DispatchQueue.main.async {
            guard self.remoteGate("play") else { return }
            self.performPlay()
        }
    }

    private func remotePause() {
        DispatchQueue.main.async {
            guard self.remoteGate("pause") else { return }
            self.performPause()
        }
    }

    private func pushNowPlaying() {
        guard !localMode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: npElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: intendedPlaybackState == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if npDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = npDuration }
        if let art = npArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = intendedPlaybackState == "playing" ? .playing : .paused
    }

    @objc func setNowPlaying(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let duration = call.getDouble("duration") ?? 0
        let artworkUrl = call.getString("artworkUrl")
        let isLocal = call.getBool("local") ?? false
        if isLocal {
            // Local file: the web view's own media session shows it on the lock screen.
            DispatchQueue.main.async { self.localMode = true; call.resolve() }
            return
        }
        DispatchQueue.main.async {
            self.localMode = false
            self.npTitle = title
            self.npArtist = artist
            self.npDuration = duration
            self.npElapsed = 0
            self.applyArtwork(urlString: artworkUrl)
            self.pushNowPlaying()
            self.broadcastWebSession()
            call.resolve()
        }
    }

    // MARK: - Artwork (YouTube thumbnail on lock screen / Dynamic Island)

    /// Builds the MPMediaItemArtwork outside of any actor-isolated closure (iOS 17+ crashes otherwise).
    private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    /// YouTube thumbnails are 16:9 pictures, hqdefault/mqdefault even have black bars; the lock screen wants a
    /// square cover - take the middle square without the bars.
    private static func squareCrop(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return img }
        let letterboxed = abs(h / w - 0.75) < 0.02          // 4:3 file with a 16:9 picture inside
        let side = letterboxed ? h * 0.75 : min(w, h)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cropped, scale: 1, orientation: img.imageOrientation)
    }

    private static func smallJpegDataUrl(_ img: UIImage) -> String? {
        let side: CGFloat = 400
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        let small = r.image { _ in img.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let jpg = small.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + jpg.base64EncodedString()
    }

    /// Candidate URLs, best first. Any http:// is upgraded (iOS blocks plain http).
    private static func artworkCandidates(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s = "https://" + String(s.dropFirst(7)) }
        var out: [String] = []
        if let r = s.range(of: "i.ytimg.com/vi/") {
            let rest = s[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let vid = String(rest[rest.startIndex..<slash])
                for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"] {
                    out.append("https://i.ytimg.com/vi/\(vid)/\(name).jpg")
                }
                if !out.contains(s) { out.insert(s, at: 0) }
                return out
            }
        }
        return [s]
    }

    /// Shows the cached picture at once (if we have it), otherwise downloads it and updates the card.
    private func applyArtwork(urlString: String?) {
        guard let raw = urlString, !raw.isEmpty else { npArtwork = nil; npArtKey = ""; npArtDataUrl = nil; return }
        let key = raw
        npArtKey = key
        if let cached = artworkCache[key] { npArtwork = cached; npArtDataUrl = artDataCache[key]; return }
        npArtwork = nil
        npArtDataUrl = nil
        let candidates = YouTubeCapacitorPlugin.artworkCandidates(raw)
        func attempt(_ i: Int) {
            guard i < candidates.count, let url = URL(string: candidates[i]) else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                guard ok, let data = data, data.count > 1500, let img = UIImage(data: data), img.size.width >= 100 else {
                    attempt(i + 1); return      // e.g. maxresdefault does not exist for every video
                }
                let square = YouTubeCapacitorPlugin.squareCrop(img)
                let art = YouTubeCapacitorPlugin.makeArtwork(square)
                let dataUrl = YouTubeCapacitorPlugin.smallJpegDataUrl(square)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.artworkCache[key] = art
                    if let d = dataUrl { self.artDataCache[key] = d }
                    if self.artworkCache.count > 40, let k = self.artworkCache.keys.first(where: { $0 != key }) { self.artworkCache.removeValue(forKey: k) }
                    if self.npArtKey == key { self.npArtwork = art; self.npArtDataUrl = dataUrl; self.pushNowPlaying(); self.broadcastWebSession() }   // still the same song
                }
            }.resume()
        }
        attempt(0)
    }

    // MARK: - Plugin methods

    @objc func load(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        DispatchQueue.main.async {
            self.lastAdvanced = nil
            self.didNotifyErrorForCurrentLoad = false
            self.didHandleEndForCurrentLoad = false
            self.lastNotifiedState = ""
            self.cachedDuration = 0
            self.isInterrupted = false
            self.localMode = false
            self.loadStartedAt = Date()
            self.cancelSilenceStop()
            self.intendedPlaybackState = "playing"
            self.activateAudioSession()
            self.silentPlayer.play()
            self.player?.load(videoId: videoId)
            self.attachPlayerWebViewIfNeeded()
            self.startStateObserver()
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.performPlay()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.performPause()
            call.resolve()
        }
    }

    /// Play/pause decided by the NATIVE state (the single source of truth), so the UI can't
    /// get out of sync with what is really happening and end up needing extra taps.
    @objc func toggle(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // Frantic tapping: a second tap within 0.18 s is ignored (we just answer with the real state),
            // otherwise play/pause commands overtake each other inside the YouTube page.
            if Date().timeIntervalSince(self.lastToggleAt) > 0.18 {
                self.lastToggleAt = Date()
                if self.intendedPlaybackState == "playing" { self.performPause() } else { self.performPlay() }
            }
            call.resolve(["playing": self.intendedPlaybackState == "playing"])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.player?.stop()
            self.cancelSilenceStop()
            self.silentPlayer.pause()
            self.stopStateObserver()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getFloat("seconds") ?? 0
        DispatchQueue.main.async {
            self.player?.seekTo(seconds, allowSeekAhead: true)
            call.resolve()
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func setUpNext(_ call: CAPPluginCall) {
        let raw = call.getArray("items", JSObject.self) ?? []
        let rep = call.getBool("repeatOne") ?? false
        DispatchQueue.main.async {
            self.repeatOne = rep
            self.upNext = raw.compactMap { o in
                guard let vid = o["videoId"] as? String, !vid.isEmpty,
                      let idx = o["index"] as? Int else { return nil }
                return UpNextItem(videoId: vid, index: idx,
                                  title: o["title"] as? String ?? "",
                                  artist: o["artist"] as? String ?? "",
                                  duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
                                  artworkUrl: o["artworkUrl"] as? String)
            }
            call.resolve()
        }
    }

    @objc func setTheme(_ call: CAPPluginCall) {
        let theme = call.getString("theme") ?? "system"
        DispatchQueue.main.async {
            let style: UIUserInterfaceStyle = theme == "light" ? .light : (theme == "dark" ? .dark : .unspecified)
            self.bridge?.viewController?.overrideUserInterfaceStyle = style
            call.resolve()
        }
    }

    /// Called when the current track ended. Returns true if we handled it natively.
    private func handleTrackEnded() -> Bool {
        if didHandleEndForCurrentLoad { return true }
        if repeatOne {
            didHandleEndForCurrentLoad = true
            intendedPlaybackState = "playing"
            player?.seekTo(0, allowSeekAhead: true)
            player?.play()
            // allow the next end to be handled again once playback restarts
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.didHandleEndForCurrentLoad = false }
            return true
        }
        guard !upNext.isEmpty else { return false }
        didHandleEndForCurrentLoad = true
        let item = upNext.removeFirst()
        didNotifyErrorForCurrentLoad = false
        lastNotifiedState = ""
        cachedDuration = 0
        loadStartedAt = Date()
        intendedPlaybackState = "playing"
        activateAudioSession()
        silentPlayer.play()
        player?.load(videoId: item.videoId)
        player?.play()
        // reset flag once the new video is actually on its way
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.didHandleEndForCurrentLoad = false }
        npTitle = item.title; npArtist = item.artist; npDuration = item.duration; npElapsed = 0
        applyArtwork(urlString: item.artworkUrl)
        pushNowPlaying()
        broadcastWebSession()
        lastAdvanced = (item.index, item.videoId)
        notifyListeners("youtubeAdvanced", data: ["index": item.index, "videoId": item.videoId])
        return true
    }

    // MARK: - State observer

    // Always called on the main thread. These used to hop through DispatchQueue.main.async,
    // so "load, then stop right after" could run as start -> stop -> (late) invalidate and
    // leave the app without any state observer: no progress, no auto-advance, no resume.
    private func startStateObserver() {
        stopStateObserver()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.notifyState()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopStateObserver() {
        timer?.invalidate()
        timer = nil
    }

    private func notifyState() {
        guard let player = self.player else { return }

        let stateStr: String
        switch player.playerState {
        case .unstarted: stateStr = "unstarted"
        case .ended: stateStr = "ended"
        case .playing: stateStr = "playing"
        case .paused: stateStr = "paused"
        case .buffering: stateStr = "buffering"
        case .cued: stateStr = "cued"
        case .unknown: stateStr = "unknown"
        }

        // Report playback errors first - the "stalled" handling below returns early
        // and would otherwise hide them (broken video = silent dead end).
        if let error = player.lastError, !didNotifyErrorForCurrentLoad {
            didNotifyErrorForCurrentLoad = true
            notifyListeners("youtubeError", data: ["error": String(describing: error)])
            return
        }

        if stateStr == "playing" && intendedPlaybackState == "paused" {
            player.pause()
            return
        }

        // The user wants music, but WebKit/iOS paused the page behind our back
        // (backgrounding, screen lock, app switch) or a freshly loaded video got stuck in
        // "cued"/"unstarted" instead of starting -> silently (re)start it and do NOT tell JS
        // it was paused, so the UI doesn't flicker and the user doesn't have to tap twice.
        let stalled = stateStr == "paused" || stateStr == "cued"
            || (stateStr == "unstarted" && Date().timeIntervalSince(loadStartedAt) > 3)
        if stalled && intendedPlaybackState == "playing" && !isInterrupted {
            if Date().timeIntervalSince(lastResumeAttempt) > 0.12 {
                lastResumeAttempt = Date()
                activateAudioSession()
                silentPlayer.play()
                player.play()
            }
            return
        }

        if stateStr == "ended" && handleTrackEnded() { return }

        if stateStr != lastNotifiedState {
            lastNotifiedState = stateStr
            notifyListeners("youtubeStateChange", data: ["state": stateStr])
            if stateStr == "playing" { broadcastWebSession() }
        }

        // Duration practically never changes while a track plays: ask for it
        // rarely instead of on every tick (halves the JS round-trips).
        let needDuration = cachedDuration <= 0 || Date().timeIntervalSince(lastDurationFetch) > 3
        let knownDuration = cachedDuration
        // At most ONE query to the web page at a time - when the page is busy (frantic tapping,
        // background) the old code piled up hundreds of waiting queries.
        if stateQueryInFlight { return }
        stateQueryInFlight = true
        Task {
            defer { DispatchQueue.main.async { self.stateQueryInFlight = false } }
            do {
                let duration: Double
                if needDuration {
                    let fetched = try await player.duration()
                    duration = fetched
                    DispatchQueue.main.async { self.cachedDuration = fetched; self.lastDurationFetch = Date() }
                } else {
                    duration = knownDuration
                }
                let currentTime = try await player.currentTime()
                self.notifyListeners("youtubeTimeUpdate", data: [
                    "currentTime": currentTime,
                    "duration": duration
                ])
                // refresh lock-screen progress about once per second
                if Date().timeIntervalSince(self.lastNowPlayingUpdate) > 1.0 {
                    self.lastNowPlayingUpdate = Date()
                    DispatchQueue.main.async {
                        self.npElapsed = Double(currentTime)
                        if duration > 0 { self.npDuration = duration }
                        self.pushNowPlaying()
                    }
                }
            } catch {
                // ignore
            }
        }
    }
}

class SilentAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?

    init() {
        engine.attach(playerNode)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(44100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData?[ch]
            for i in 0..<Int(frames) { data?[i] = 0.0 }
        }
        silentBuffer = buffer
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// Restart ONLY if iOS stopped the engine.
    func recoverIfNeeded() {
        if engine.isRunning && playerNode.isPlaying { return }
        restart()
    }

    func play() {
        do {
            if !engine.isRunning { try engine.start() }
            if !playerNode.isPlaying { playerNode.play() }
        } catch {
            print("Failed to start silent audio engine")
        }
    }

    func pause() {
        playerNode.pause()
        engine.pause()
    }

    func restart() {
        playerNode.stop()                 // stop() drops the scheduled buffer ...
        engine.stop()
        if let b = silentBuffer { playerNode.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }   // ... so queue it again
        play()
    }
}
