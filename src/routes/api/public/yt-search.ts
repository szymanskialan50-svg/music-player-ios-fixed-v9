import { createFileRoute } from "@tanstack/react-router";

type YtItem = {
  videoId: string;
  title: string;
  artist: string;
  duration: number | null;
  thumb: string | null;
};

function decodeEntities(s: string) {
  return String(s ?? "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

function parseISODuration(iso: string): number | null {
  const m = /^P(?:([\d.]+)D)?T?(?:([\d.]+)H)?(?:([\d.]+)M)?(?:([\d.]+)S)?$/.exec(iso || "");
  if (!m) return null;
  const [, d, h, mi, s] = m;
  const total =
    (parseFloat(d || "0") || 0) * 86400 +
    (parseFloat(h || "0") || 0) * 3600 +
    (parseFloat(mi || "0") || 0) * 60 +
    (parseFloat(s || "0") || 0);
  return total > 0 ? Math.round(total) : null;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=300",
      "access-control-allow-origin": "*",
    },
  });

export const Route = createFileRoute("/api/public/yt-search")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const url = new URL(request.url);
        const q = (url.searchParams.get("q") || "").trim().slice(0, 120);
        const hl = (url.searchParams.get("hl") || "en").slice(0, 5);
        const rawRegion = (url.searchParams.get("region") || "").slice(0, 2).toUpperCase();
        const regionCode = /^[A-Z]{2}$/.test(rawRegion) ? rawRegion : "";
        if (!q) return json({ items: [] });

        const key = process.env["GOOGLE_API_KEY"];
        if (!key) return json({ error: "missing_key" }, 500);

        const searchUrl = new URL("https://www.googleapis.com/youtube/v3/search");
        searchUrl.searchParams.set("part", "snippet");
        searchUrl.searchParams.set("type", "video");
        searchUrl.searchParams.set("videoCategoryId", "10");
        searchUrl.searchParams.set("videoEmbeddable", "true");
        searchUrl.searchParams.set("maxResults", "25");
        searchUrl.searchParams.set("q", q);
        searchUrl.searchParams.set("relevanceLanguage", hl);
        if (regionCode) searchUrl.searchParams.set("regionCode", regionCode);
        searchUrl.searchParams.set("key", key);

        const sRes = await fetch(searchUrl.toString());
        if (!sRes.ok) {
          const detail = await sRes.text();
          return json({ error: "youtube_error", status: sRes.status, detail: detail.slice(0, 400) }, 502);
        }
        const sData = (await sRes.json()) as {
          items?: Array<{
            id?: { videoId?: string };
            snippet?: { title?: string; channelTitle?: string; thumbnails?: Record<string, { url?: string }> };
          }>;
        };

        const base = new Map<string, YtItem>();
        for (const it of sData.items ?? []) {
          const id = it.id?.videoId;
          if (!id || base.has(id)) continue;
          base.set(id, {
            videoId: id,
            title: decodeEntities(it.snippet?.title ?? ""),
            artist: decodeEntities(it.snippet?.channelTitle ?? ""),
            duration: null,
            thumb:
              it.snippet?.thumbnails?.["medium"]?.url ??
              it.snippet?.thumbnails?.["default"]?.url ??
              null,
          });
        }
        const ids = [...base.keys()];
        if (!ids.length) return json({ items: [] });

        const vUrl = new URL("https://www.googleapis.com/youtube/v3/videos");
        vUrl.searchParams.set("part", "contentDetails,snippet,status");
        vUrl.searchParams.set("id", ids.join(","));
        vUrl.searchParams.set("key", key);

        const vRes = await fetch(vUrl.toString());
        if (vRes.ok) {
          const vData = (await vRes.json()) as {
            items?: Array<{
              id?: string;
              contentDetails?: { duration?: string };
              status?: { embeddable?: boolean };
              snippet?: { title?: string; channelTitle?: string };
            }>;
          };
          for (const v of vData.items ?? []) {
            const item = v.id ? base.get(v.id) : undefined;
            if (!item) continue;
            item.duration = parseISODuration(v.contentDetails?.duration ?? "");
            if (v.snippet?.title) item.title = decodeEntities(v.snippet.title);
            if (v.snippet?.channelTitle) item.artist = decodeEntities(v.snippet.channelTitle);
            if (v.status && v.status.embeddable === false) base.delete(v.id!);
          }
        }

        return json({ items: [...base.values()] });
      },
    },
  },
});
