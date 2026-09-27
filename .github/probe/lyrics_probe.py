import json, urllib.request, urllib.parse
def get(path, q):
    req = urllib.request.Request("https://lrclib.net/api/%s?%s" % (path, urllib.parse.urlencode(q)), headers={"User-Agent": "FrozenMusic probe"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except Exception as e:
        return "ERR %s" % e
for title, dur in [("Intro", 277), ("Sweden", 216), ("Wet Hands", 90)]:
    g = get("get", {"artist_name": "C418", "track_name": title, "album_name": "Minecraft - Volume Beta" if title == "Intro" else "Minecraft - Volume Alpha", "duration": dur})
    print("GET", title, json.dumps(g)[:300] if not isinstance(g, str) else g)
    s = get("search", {"artist_name": "C418", "track_name": title})
    if isinstance(s, list):
        for e in s[:5]:
            print("  SEARCH", e.get("trackName"), "|", e.get("artistName"), "|", e.get("albumName"), "|", e.get("duration"), "| instr", e.get("instrumental"), "| synced", bool(e.get("syncedLyrics")), "| plain", (e.get("plainLyrics") or "")[:40].replace("\n"," / "))
    else:
        print("  SEARCH", s)
