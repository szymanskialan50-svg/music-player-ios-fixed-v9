import { registerPlugin } from '@capacitor/core';
import type { YouTubeCapacitorPlugin } from './definitions';

const YouTubePlayerNative = registerPlugin<YouTubeCapacitorPlugin>('YouTubeCapacitorPlugin');

export * from './definitions';
export { YouTubePlayerNative };
