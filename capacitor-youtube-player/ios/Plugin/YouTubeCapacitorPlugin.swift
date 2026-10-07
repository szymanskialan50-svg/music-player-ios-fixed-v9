import Foundation
import Capacitor
import AVFoundation
import MediaPlayer
import UIKit
import Combine
import YouTubePlayerKit

@MainActor
@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {

    private var player: YouTubePlayer?
    private var timer: Timer?
    private var intendedPlaybackState = "paused"
    private let silentPlayer = SilentAudioPlayer()
    private var didNotifyErrorForCurrentLoad = false
    private var lastNotifiedState = ""
    private var cachedDuration: Double = 0
    private var lastDurationFetch = Date.distantPast

    private var isInterrupted = false
    private var lastResumeAttempt = Date.distantPast
    private var lastNowPlayingUpdate = Date.distantPast
    private var loadStartedAt = Date.distantPast

    private var localMode = false
    private var lockSkipMode = true

    private var silenceStopWork: DispatchWorkItem?

    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?
    private var npArtKey = ""
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artDataCache: [String: String] = [:]
    private var npArtDataUrl: String?

    private var resumeGeneration = 0
    private var lastToggleAt = Date.distantPast
    private var remoteGateTimes: [String: Date] = [:]
    private var stateQueryInFlight = false
    private var npDuration: Double = 0
    private var npElapsed: Double = 0
    private var remoteCommandsConfigured = false

    private struct UpNextItem {
        let videoId: String; let index: Int
        let title: String; let artist: String
        let duration: Double; let artworkUrl: String?
    }
    private var upNext: [UpNextItem] = []
    private var repeatOne = false
    private var didHandleEndForCurrentLoad = false
    private var lastAdvanced: (index: Int, videoId: String)?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private var cancellables = Set<AnyCancellable>()

    public override func load() {
        super.load()
        DispatchQueue.main.async {
            self.activateAudioSession(force: true)
            self.silentPlayer.play()
            UIApplication.shared.beginReceivingRemoteControlEvents()

            self.player = YouTubePlayer(
                parameters: .init(
                    autoPlay: true,
                    showControls: false,
                    showFullscreenButton: false
                ),
                configuration: .init(
                    allowsInlineMediaPlayback: true
                )
            )

            self.player?.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.handlePlayerState(state)
                }
                .store(in: &self.cancellables)

            self.player?.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] playbackState in
                    if let state = playbackState {
                        self?.handlePlaybackState(state)
                    }
                }
                .store(in: &self.cancellables)

            self.attachPlayerWebViewIfNeeded()
            self.setupRemoteCommands()

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: nil)
            nc.addObserver(self, selector: #selector(self.routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)

            self.startStateObserver()
        }
    }

    private func handlePlayerState(_ state: YouTubePlayer.State) {
        if case .error(let error) = state {
            if !didNotifyErrorForCurrentLoad {
                didNotifyErrorForCurrentLoad = true
                notifyListeners("youtubeError", data: ["error": String(describing: error)])
            }
        }
    }

    private func handlePlaybackState(_ state: YouTubePlayer.PlaybackState) {
        let stateStr: String
        switch state {
        case .unstarted: stateStr = "unstarted"
        case .ended: stateStr = "ended"
        case .playing: stateStr = "playing"
        case .paused: stateStr = "paused"
        case .buffering: stateStr = "buffering"
        case .cued: stateStr = "cued"
        default: stateStr = "unknown"
        }

        if stateStr == "playing" && intendedPlaybackState == "paused" {
            Task { try? await self.player?.pause() }
            return
        }

        let stalled = stateStr == "paused" || stateStr == "cued"
            || (stateStr == "unstarted" && Date().timeIntervalSince(loadStartedAt) > 3)
        if stalled && intendedPlaybackState == "playing" && !isInterrupted {
            if Date().timeIntervalSince(lastResumeAttempt) > 0.12 {
                lastResumeAttempt = Date()
                activateAudioSession()
                silentPlayer.play()
                Task { try? await self.player?.play() }
            }
            return
        }

        if stateStr == "ended" && handleTrackEnded() { return }

        if stateStr != lastNotifiedState {
            lastNotifiedState = stateStr
            notifyListeners("youtubeStateChange", data: ["state": stateStr])
            if stateStr == "playing" { broadcastWebSession() }
        }
    }

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
        pushNowPlaying()
        resumeIfIntended()
    }

    private func performPause() {
        intendedPlaybackState = "paused"
        resumeGeneration &+= 1
        Task { try? await player?.pause() }
        keepSessionAliveWhilePaused()
        pushNowPlaying()
    }

    private func resumeIfIntended() {
        guard intendedPlaybackState == "playing", !isInterrupted else { return }
        activateAudioSession()
        silentPlayer.play()
        Task { try? await player?.play() }
        resumeGeneration &+= 1
        let gen = resumeGeneration
        for delay in [0.05, 0.15, 0.35, 0.7, 1.3, 2.5, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, gen == self.resumeGeneration,
                      self.intendedPlaybackState == "playing", !self.isInterrupted else { return }

                let state = self.player?.playbackStateSubject.value
                if state != .playing && state != .buffering {
                    self.activateAudioSession()
                    self.silentPlayer.play()
                    Task { try? await self.player?.play() }
                }
            }
        }
    }

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
            self.pushNowPlaying()
            if self.intendedPlaybackState == "playing" {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
        }
    }

    @objc func appDidBecomeActive() {
        DispatchQueue.main.async {
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            self.lastNotifiedState = ""
            self.resumeIfIntended()
            self.pushNowPlaying()
            self.broadcastWebSession()
            if let a = self.lastAdvanced {
                self.notifyListeners("youtubeAdvanced", data: ["index": a.index, "videoId": a.videoId])
            }
        }
    }

    @objc func engineConfigChanged() {
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
        guard reason == .oldDeviceUnavailable else { return }

        let headsetPorts: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let previous = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let hadHeadset = previous?.outputs.contains(where: { output in
            headsetPorts.contains(output.portType)
        }) ?? false
        guard hadHeadset else { return }

        DispatchQueue.main.async {
            let stillHeadset = AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { output in
                headsetPorts.contains(output.portType)
            })
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
            } else {
                self.isInterrupted = false
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
            Task { try? await self.player?.seek(to: Measurement(value: e.positionTime, unit: .seconds), allowSeekAhead: true) }
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

    private func applyLockScreenMode() {
        let cc = MPRemoteCommandCenter.shared()
        cc.skipForwardCommand.isEnabled = lockSkipMode
        cc.skipBackwardCommand.isEnabled = lockSkipMode
        cc.nextTrackCommand.isEnabled = !lockSkipMode
        cc.previousTrackCommand.isEnabled = !lockSkipMode
    }

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

    private func broadcastWebSession() {
        // Nothing needed here since we don't sync with WebSession anymore
    }

    private func remoteSkip(_ delta: Double) {
        DispatchQueue.main.async {
            guard self.remoteGate(delta > 0 ? "skip+" : "skip-") else { return }
            var target = self.npElapsed + delta
            if self.npDuration > 0 { target = min(target, max(0, self.npDuration - 1)) }
            target = max(0, target)
            Task { try? await self.player?.seek(to: Measurement(value: target, unit: .seconds), allowSeekAhead: true) }
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

    private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private static func squareCrop(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return img }
        let letterboxed = abs(h / w - 0.75) < 0.02
        let side = letterboxed ? h * 0.75 : min(w, h)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cropped, scale: 1, orientation: img.imageOrientation)
    }

    private static func smallJpegDataUrl(_ img: UIImage) -> String? {
        let side: CGFloat = 400
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        let jpg = small.image { _ in img.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let data = jpg.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

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
                    attempt(i + 1); return
                }
                let square = YouTubeCapacitorPlugin.squareCrop(img)
                let art = YouTubeCapacitorPlugin.makeArtwork(square)
                let dataUrl = YouTubeCapacitorPlugin.smallJpegDataUrl(square)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.artworkCache[key] = art
                    if let d = dataUrl { self.artDataCache[key] = d }
                    if self.artworkCache.count > 40, let k = self.artworkCache.keys.first(where: { $0 != key }) { self.artworkCache.removeValue(forKey: k) }
                    if self.npArtKey == key { self.npArtwork = art; self.npArtDataUrl = dataUrl; self.pushNowPlaying(); self.broadcastWebSession() }
                }
            }.resume()
        }
        attempt(0)
    }

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
            self.player?.source = .video(id: videoId)
            self.attachPlayerWebViewIfNeeded()
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

    @objc func toggle(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
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
            Task { try? await self.player?.stop() }
            self.cancelSilenceStop()
            self.silentPlayer.pause()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getDouble("seconds") ?? 0
        DispatchQueue.main.async {
            Task { try? await self.player?.seek(to: Measurement(value: seconds, unit: .seconds), allowSeekAhead: true) }
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

    private func handleTrackEnded() -> Bool {
        if didHandleEndForCurrentLoad { return true }
        if repeatOne {
            didHandleEndForCurrentLoad = true
            intendedPlaybackState = "playing"
            Task {
                try? await self.player?.seek(to: Measurement(value: 0, unit: .seconds), allowSeekAhead: true)
                try? await self.player?.play()
            }
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
        self.player?.source = .video(id: item.videoId)
        Task { try? await self.player?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.didHandleEndForCurrentLoad = false }
        npTitle = item.title; npArtist = item.artist; npDuration = item.duration; npElapsed = 0
        applyArtwork(urlString: item.artworkUrl)
        pushNowPlaying()
        broadcastWebSession()
        lastAdvanced = (item.index, item.videoId)
        notifyListeners("youtubeAdvanced", data: ["index": item.index, "videoId": item.videoId])
        return true
    }

    private func startStateObserver() {
        stopStateObserver()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollProgress()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopStateObserver() {
        timer?.invalidate()
        timer = nil
    }

    private func pollProgress() {
        let needDuration = cachedDuration <= 0 || Date().timeIntervalSince(lastDurationFetch) > 3
        let knownDuration = cachedDuration
        if stateQueryInFlight { return }
        stateQueryInFlight = true
        Task {
            defer { DispatchQueue.main.async { self.stateQueryInFlight = false } }
            do {
                let duration: Double
                if needDuration {
                    if let fetched = try? await player?.getDuration() {
                        duration = fetched.value
                        DispatchQueue.main.async { self.cachedDuration = duration; self.lastDurationFetch = Date() }
                    } else {
                        duration = knownDuration
                    }
                } else {
                    duration = knownDuration
                }
                if let currentTime = try? await player?.getCurrentTime() {
                    self.notifyListeners("youtubeTimeUpdate", data: [
                        "currentTime": currentTime.value,
                        "duration": duration
                    ])
                    if Date().timeIntervalSince(self.lastNowPlayingUpdate) > 1.0 {
                        self.lastNowPlayingUpdate = Date()
                        DispatchQueue.main.async {
                            self.npElapsed = Double(currentTime.value)
                            if duration > 0 { self.npDuration = duration }
                            self.pushNowPlaying()
                        }
                    }
                }
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
        playerNode.stop()
        engine.stop()
        if let b = silentBuffer { playerNode.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }
        play()
    }
}
