import json, urllib.request

def post(endpoint, body, client="WEB_REMIX", version="1.20250101.01.00"):
    body = dict(body); body["context"] = {"client": {"clientName": client, "clientVersion": version, "hl": "en", "gl": "US"}}
    req = urllib.request.Request("https://music.youtube.com/youtubei/v1/%s?prettyPrint=false" % endpoint, data=json.dumps(body).encode(), method="POST", headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
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

def runs(x):
    return "".join(r.get("text", "") for r in (x or {}).get("runs", []))

for q in ["C418 Intro Minecraft Volume Beta", "C418 Sweden", "C418 Wet Hands"]:
    print("=" * 20, q)
    s = post("search", {"query": q, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="})
    items = find(s, "musicResponsiveListItemRenderer", [])
    for it in items[:3]:
        vid = (find(it, "videoId", []) or [None])[0]
        cols = [runs(c.get("musicResponsiveListItemFlexColumnRenderer", {}).get("text")) for c in it.get("flexColumns", [])]
        print("RESULT", vid, cols)
    vid = (find(items[0], "videoId", []) or [None])[0]
    n = post("next", {"videoId": vid})
    tabs = find(n, "tabRenderer", [])
    lyr = [t for t in tabs if str(t.get("endpoint", {}).get("browseEndpoint", {}).get("browseId", "")).startswith("MPLY")]
    print("tab keys", [list(t.keys()) for t in tabs][:2])
    if not lyr:
        continue
    bid = lyr[0]["endpoint"]["browseEndpoint"]["browseId"]
    b = post("browse", {"browseId": bid})
    shelf = find(b, "musicDescriptionShelfRenderer", [])
    if shelf:
        print("PLAIN:", runs(shelf[0].get("description"))[:200].replace("\n", " / "), "|", runs(shelf[0].get("footer")))
    else:
        msgs = find(b, "text", [])
        print("NO SHELF; texts:", json.dumps(find(b, "runs", [])[:4])[:400])
    t = post("browse", {"browseId": bid}, "ANDROID_MUSIC", "7.21.50")
    timed = find(t, "timedLyricsData", [])
    print("TIMED lines:", len(timed[0]) if timed else 0, json.dumps(timed[0][:2])[:200] if timed else "")
