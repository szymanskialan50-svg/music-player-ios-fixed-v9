// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import Foundation

// MARK: - Player State

/// The current playback state of the YouTube player.
///
/// Maps to IFrame API player state codes:
/// https://developers.google.com/youtube/iframe_api_reference#Playback_status
public enum YouTubePlayerState: Int, Sendable {
    case unstarted = -1
    case ended = 0
    case playing = 1
    case paused = 2
    case buffering = 3
    case cued = 5
    case unknown = -99
    
    init(code: String) {
        switch code {
        case "-1": self = .unstarted
        case "0":  self = .ended
        case "1":  self = .playing
        case "2":  self = .paused
        case "3":  self = .buffering
        case "5":  self = .cued
        default:   self = .unknown
        }
    }
}

// MARK: - Playback Quality

/// The resolution of the currently loaded video.
public enum YouTubePlaybackQuality: String, Sendable {
    case small     = "small"
    case medium    = "medium"
    case large     = "large"
    case hd720     = "hd720"
    case hd1080    = "hd1080"
    case highRes   = "highres"
    case auto      = "auto"
    case `default` = "default"
    case unknown   = "unknown"
    
    init(string: String) {
        self = YouTubePlaybackQuality(rawValue: string) ?? .unknown
    }
}

// MARK: - Player Error

/// An error reported by the YouTube IFrame player.
///
/// https://developers.google.com/youtube/iframe_api_reference#Events (onError)
public enum YouTubePlayerError: Error, Sendable, Equatable {
    /// The request contained an invalid parameter value (code 2).
    case invalidParam
    /// The requested content cannot be played in an HTML5 player (code 5).
    case html5Error
    /// The video requested was not found (codes 100, 105).
    case videoNotFound
    /// The owner of the video does not allow it to be played in embedded players (codes 101, 150).
    case notEmbeddable
    /// The YouTube IFrame API script failed to load (e.g. no internet connection).
    case apiFailedToLoad
    /// An unknown error occurred.
    case unknown
    
    init(code: String) {
        switch code {
        case "2":          self = .invalidParam
        case "5":          self = .html5Error
        case "100", "105": self = .videoNotFound
        case "101", "150": self = .notEmbeddable
        default:           self = .unknown
        }
    }
}

// MARK: - Player Variables

/// Strongly-typed configuration for the YouTube IFrame player.
///
/// Pass this to `load(videoId:playerVars:)` or `load(playlistId:playerVars:)`.
///
/// ```swift
/// player.load(videoId: "dQw4w9WgXcQ", playerVars: YouTubePlayerVars(
///     autoplay: true,
///     controls: false,
///     playsInline: true,
///     start: 30
/// ))
/// ```
public struct YouTubePlayerVars: Sendable {
    
    // MARK: - Playback
    
    /// Start playback automatically when the player loads. Default: `false`.
    public var autoplay: Bool?
    
    /// Begin playback at this offset, in seconds, from the start of the video.
    public var start: Int?
    
    /// Stop playback at this offset, in seconds, from the start of the video.
    public var end: Int?
    
    /// Loop the video (or playlist) indefinitely. Default: `false`.
    public var loop: Bool?
    
    // MARK: - UI
    
    /// Show the player controls bar. Default: `true`.
    public var controls: Bool?
    
    /// Show the fullscreen button. Default: `true`.
    public var fullscreen: Bool?
    
    /// When `false`, only videos from the same channel are shown in the end-screen related videos.
    /// Default: `true` (videos from any channel).
    public var relatedVideos: Bool?
    
    /// Color of the video progress bar. Default: `.red`.
    ///
    /// Setting `.white` disables modest branding mode.
    public var progressBarColor: ProgressBarColor?
    
    // MARK: - Behavior
    
    /// Allow keyboard shortcuts to control the player. Default: `true`.
    public var keyboardControls: Bool?
    
    /// Play video inline on iPhone instead of entering full-screen automatically. Default: `false`.
    public var playsInline: Bool?
    
    /// Show video annotations overlaid on the video. Default: `true`.
    public var annotations: Bool?
    
    // MARK: - Captions
    
    /// Default caption language (BCP-47 tag, e.g. `"en"`, `"vi"`).
    ///
    /// The user can still change the language from the player controls.
    public var captionLanguage: String?
    
    /// Always show captions, overriding the user's saved preference. Default: `false`.
    public var showCaptions: Bool?
    
    // MARK: - Localization
    
    /// Language of the player UI (BCP-47 tag, e.g. `"en"`, `"vi"`).
    public var language: String?
    
    // MARK: - Nested Types
    
    /// The color of the video progress/seek bar.
    public enum ProgressBarColor: String, Sendable {
        /// The default YouTube red.
        case red = "red"
        /// A white progress bar.
        case white = "white"
    }
    
    // MARK: - Init
    
    public init(
        autoplay: Bool? = nil,
        start: Int? = nil,
        end: Int? = nil,
        loop: Bool? = nil,
        controls: Bool? = nil,
        fullscreen: Bool? = nil,
        relatedVideos: Bool? = nil,
        progressBarColor: ProgressBarColor? = nil,
        keyboardControls: Bool? = nil,
        playsInline: Bool? = nil,
        annotations: Bool? = nil,
        captionLanguage: String? = nil,
        showCaptions: Bool? = nil,
        language: String? = nil
    ) {
        self.autoplay = autoplay
        self.start = start
        self.end = end
        self.loop = loop
        self.controls = controls
        self.fullscreen = fullscreen
        self.relatedVideos = relatedVideos
        self.progressBarColor = progressBarColor
        self.keyboardControls = keyboardControls
        self.playsInline = playsInline
        self.annotations = annotations
        self.captionLanguage = captionLanguage
        self.showCaptions = showCaptions
        self.language = language
    }
    
    // MARK: - Internal
    
    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [:]
        if let autoplay          { d["autoplay"]        = autoplay ? 1 : 0 }
        if let start             { d["start"]           = start }
        if let end               { d["end"]             = end }
        if let loop              { d["loop"]            = loop ? 1 : 0 }
        if let controls          { d["controls"]        = controls ? 1 : 0 }
        if let fullscreen        { d["fs"]              = fullscreen ? 1 : 0 }
        if let relatedVideos     { d["rel"]             = relatedVideos ? 1 : 0 }
        if let progressBarColor  { d["color"]           = progressBarColor.rawValue }
        if let keyboardControls  { d["disablekb"]       = keyboardControls ? 0 : 1 }
        if let playsInline       { d["playsinline"]     = playsInline ? 1 : 0 }
        if let annotations       { d["iv_load_policy"]  = annotations ? 1 : 3 }
        if let captionLanguage   { d["cc_lang_pref"]    = captionLanguage }
        if let showCaptions      { d["cc_load_policy"]  = showCaptions ? 1 : 0 }
        if let language          { d["hl"]              = language }
        return d
    }
}

// MARK: - Player Phase

/// The current phase of the YouTube player lifecycle
public enum YouTubePlayerPhase: Sendable, Equatable {
    /// The player is loading or has not yet been initialized.
    case loading
    /// The player is ready and active with the given playback state.
    case active(YouTubePlayerState)
    /// The player encountered an error.
    case failed(YouTubePlayerError)
}
