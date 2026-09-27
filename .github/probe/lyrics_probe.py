import json, urllib.request

def post(endpoint, body, client="WEB_REMIX", version="1.20250101.01.00"):
    body = dict(body); body["context"] = {"client": {"clientName": client, "clientVersion": version, "hl": "en", "gl": "US"}}
    req = urllib.request.Request("https://music.youtube.com/youtubei/v1/%s?prettyPrint=false" % endpoint, data=json.dumps(body).encode(), method="POST", headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)

def paths(obj, path=""):
    if isinstance(obj, dict):
        be = obj.get("browseEndpoint")
        if isinstance(be, dict) and str(be.get("browseId", "")).startswith("MPLY"):
            yield path, be.get("browseId")
        for k, v in obj.items():
            yield from paths(v, path + "/" + k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from paths(v, path + "[%d]" % i)

def find(obj, key, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key: out.append(v)
            find(v, key, out)
    elif isinstance(obj, list):
        for v in obj: find(v, key, out)
    return out

for q in ["C418 Intro Minecraft Volume Beta", "C418 Sweden"]:
    print("=" * 20, q)
    s = post("search", {"query": q, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="})
    vids = []
    for v in find(s, "videoId", []):
        if v not in vids: vids.append(v)
    print("videoIds", vids[:4])
    vid = vids[0]
    n = post("next", {"videoId": vid})
    for t in find(n, "tabRenderer", []):
        print("TAB", t.get("title"), json.dumps(t.get("endpoint", {}))[:160], "unselectable" if t.get("unselectable") else "")
    for p, b in paths(n):
        print("MPLY at", p[:220], b)
