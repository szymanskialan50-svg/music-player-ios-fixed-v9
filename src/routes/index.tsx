import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Music Player — YouTube Search & Offline Library" },
      {
        name: "description",
        content:
          "Minimal music player: search the YouTube database, see real track durations and build your own library and playlists.",
      },
      { property: "og:title", content: "Music Player — YouTube Search & Offline Library" },
      {
        property: "og:description",
        content:
          "Search music powered by the YouTube Data API, add tracks to your library and organize them into playlists.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  beforeLoad: () => {
    throw redirect({ href: "/player.html" });
  },
  component: () => null,
});
