import json, urllib.request, urllib.parse

def post(endpoint, body, client, version, extra_headers=None):
    ctx = {"client": {"clientName": client, "clientVersion": version, "hl": "en", "gl": "US"}}
    body = dict(body); body["context"] = ctx
    req = urllib.request.Request("https://music.youtube.com/youtubei/v1/%s?prettyPrint=false" % endpoint,
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0", **(extra_headers or {})})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)

def find(obj, key, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key: out.append(v)
            find(v, key, out)
    elif isinstance(obj, list):
        for v in obj: find(v, key, out)
    return out

def keys_path(obj, depth=0, maxd=9):
    if depth > maxd: return
    if isinstance(obj, dict):
        for k, v in obj.items():
            print("  " * depth + k + (" = " + repr(v)[:80] if not isinstance(v, (dict, list)) else ""))
            keys_path(v, depth + 1, maxd)
    elif isinstance(obj, list) and obj:
        print("  " * depth + "[%d]" % len(obj))
        keys_path(obj[0], depth + 1, maxd)

for query in ["Tame Impala Let It Happen", "Ito Kanako Sky Clad no Kansokusha"]:
    print("=" * 30, query)
    s = post("search", {"query": query, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="}, "WEB_REMIX", "1.20250101.01.00")
    vids = find(s, "videoId", [])
    print("videoIds", vids[:3])
    vid = vids[0]
    n = post("next", {"videoId": vid}, "WEB_REMIX", "1.20250101.01.00")
    tabs = find(n, "tabRenderer", [])
    browse = None
    for t in tabs:
        bid = t.get("endpoint", {}).get("browseEndpoint", {}).get("browseId", "")
        print("tab", t.get("title"), bid)
        if bid.startswith("MPLY"): browse = bid
    print("lyrics browseId", browse)
    if not browse: continue
    b = post("browse", {"browseId": browse}, "WEB_REMIX", "1.20250101.01.00")
    print("--- WEB_REMIX browse")
    shelf = find(b, "musicDescriptionShelfRenderer", [])
    if shelf:
        print("desc", json.dumps(shelf[0].get("description"))[:300])
        print("footer", json.dumps(shelf[0].get("footer"))[:200])
    for client, version in [("ANDROID_MUSIC", "7.21.50"), ("IOS_MUSIC", "7.21.50"), ("IOS_MUSIC", "8.47.54")]:
        print("---", client, version)
        try:
            t = post("browse", {"browseId": browse}, client, version)
            timed = find(t, "timedLyricsData", [])
            print("timedLyricsData found:", len(timed))
            if timed:
                print(json.dumps(timed[0][:3]))
                src = find(t, "sourceMessage", [])
                print("sourceMessage", src[:1])
                keys_path(t, maxd=8)
            else:
                shelf = find(t, "musicDescriptionShelfRenderer", [])
                print("plain shelf:", bool(shelf))
                keys_path(t, maxd=5)
        except Exception as e:
            print("ERR", e)

print("=" * 30, "lrclib")
try:
    with urllib.request.urlopen(urllib.request.Request("https://lrclib.net/api/get?" + urllib.parse.urlencode({"artist_name": "Tame Impala", "track_name": "Let It Happen", "duration": 468}), headers={"User-Agent": "FrozenMusic probe"}), timeout=20) as r:
        d = json.load(r); print("synced", (d.get("syncedLyrics") or "")[:200])
except Exception as e:
    print("ERR", e)
print("=" * 30, "translate")
try:
    with urllib.request.urlopen("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q=" + urllib.parse.quote("過去は離れて行き 未来は近づくの?\n観測者はいつか 矛盾に気付く"), timeout=20) as r:
        print(r.read()[:400])
except Exception as e:
    print("ERR", e)
