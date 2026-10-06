import type { CapacitorConfig } from "@capacitor/cli";

// TODO: change "appId" to something unique to you before publishing
// (reverse-domain style, e.g. "com.twojanazwa.musicplayer").
// It only needs to be unique if you plan to publish to the App Store / Play
// Store — for a personal side-loaded build the default below is fine.
const config: CapacitorConfig = {
  appId: "com.musicplayer.app",
  appName: "Music Player",
  // The whole app is the single self-contained public/player.html file.
  // `npm run prepare:www` copies it into www/index.html before `cap sync`.
  webDir: "www",
  server: {
    hostname: "com.musicplayer.app",
    androidScheme: "https",
    iosScheme: "https"
  },
  ios: {
    allowsInlineMediaPlayback: true
  },
  plugins: {
    // Routes fetch()/XHR through native networking on-device instead of the
    // WebView, so the direct calls to googleapis.com in player.html are not
    // subject to any WebView CORS quirks.
    CapacitorHttp: {
      enabled: true,
    },
  },
};

export default config;
