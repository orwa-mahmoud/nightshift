import json, sys


def jtype(v):
    if v is None:
        return "null"
    if v is True or v is False:
        return "boolean"
    if isinstance(v, str):
        return "string"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, list):
        return "array"
    return "number"


def p(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
out = []
if not isinstance(d, dict):
    out.append("k\tother")
else:
    out.append("k\tobject")
    for tag, key in (("s", "stage"), ("c", "capabilityId"), ("w", "workTarget"),
                     ("f", "failed"), ("r", "recipePath")):
        out.append("%s\t%s" % (tag, p(d.get(key))))
    for tag, key, mark in (("g", "touched", "u"), ("a", "allowedFiles", "p")):
        seq = d.get(key)
        out.append("%s\t%s" % (tag, jtype(seq)))
        if isinstance(seq, list):
            out.extend("%s\t%s" % (mark, p(x)) for x in seq)
    b = d.get("baseline")
    out.append("b\t%s" % jtype(b))
    if isinstance(b, dict):
        for rel in sorted(b):
            v = b[rel]
            if isinstance(v, dict):
                has = "1" if isinstance(v.get("content"), str) and v.get("content") else "0"
                row = (p(rel), "object", p(v.get("existed")), p(v.get("digest")),
                       p(v.get("blob")), has)
            else:
                row = (p(rel), jtype(v), "null", "null", "null", "0")
            out.append("e\t%s" % "\t".join(row))
sys.stdout.write("".join(line + "\n" for line in out))
