import type { PluginListenerHandle } from '@capacitor/core';

export interface YouTubeCapacitorPlugin {
  load(options: { videoId: string }): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  /** Play/pause decided by the native state; resolves with the new state. */
  toggle(): Promise<{ playing: boolean }>;
  /** 'skip' = lock screen shows -10s/+10s, 'tracks' = previous/next track. */
  setLockScreenMode(options: { mode: 'skip' | 'tracks' }): Promise<void>;
  stop(): Promise<void>;
  seekTo(options: { seconds: number }): Promise<void>;
  setVolume(options: { volume: number }): Promise<void>;
  setUpNext(options: { items: Array<{ videoId: string; index: number; title: string; artist: string; duration: number; artworkUrl?: string }>; repeatOne: boolean }): Promise<void>;
  setTheme(options: { theme: 'dark' | 'light' | 'system' }): Promise<void>;
  setNowPlaying(options: { title: string; artist: string; duration: number; artworkUrl?: string; local?: boolean }): Promise<void>;

  addListener(
    eventName: 'youtubeStateChange',
    listenerFunc: (state: { state: string }) => void,
  ): Promise<PluginListenerHandle>;

  addListener(
    eventName: 'youtubeTimeUpdate',
    listenerFunc: (state: { currentTime: number, duration: number }) => void,
  ): Promise<PluginListenerHandle>;
}
