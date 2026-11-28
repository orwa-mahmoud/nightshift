import json, re, sys

FS, RS = sys.argv[1], sys.argv[2]
CTRL = re.compile(r"[\x00-\x1f\x7f]")
out = []


def enc(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def txt(v):
    return CTRL.sub(" ", v if isinstance(v, str) else enc(v))


def field(r, k):
    return r.get(k) if isinstance(r, dict) else None


def obj(v):
    return v if isinstance(v, dict) else {}


def arr(v):
    return v if isinstance(v, list) else []


def frame(fields):
    out.append(FS.join(fields) + RS)


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
lines = [one for one in text.split("\n") if one != ""]
for i, line in enumerate(lines):
    n = str(i)
    try:
        rec = json.loads(line)
    except ValueError:
        frame(["b", n])
        continue
    d = obj(field(rec, "details"))
    frame(["f", n,
           enc(field(rec, "domain")), enc(field(rec, "sourceClass")),
           enc(field(rec, "status")), enc(field(rec, "disposition")),
           enc(field(rec, "duplicateOf")),
           enc(field(rec, "id")), enc(field(rec, "digest")), enc(field(rec, "locator")),
           txt(field(rec, "id")), txt(field(rec, "digest")), txt(field(rec, "locator")),
           txt(field(rec, "sourceClass")), txt(field(rec, "source"))])
    for k, one in enumerate(arr(field(rec, "sources"))):
        frame(["s", n, str(k), "s" if isinstance(one, str) else "x", enc(one), txt(one)])
    if isinstance(d.get("environmentDigest"), str):
        frame(["e", n, enc(d["environmentDigest"])])
    for k, one in enumerate(arr(d.get("seen"))):
        entry = obj(one)
        frame(["o", n, str(k),
               enc(entry.get("id")), enc(entry.get("digest")),
               txt(entry.get("id")), txt(entry.get("digest"))])
sys.stdout.write("".join(out))
