import json, re, sys

SCALARS = ["schemaVersion", "shiftId", "createdAt", "source", "deadlineEpoch",
           "verificationLevel", "toolingPolicy", "launchScope", "launchProvenance",
           "completionMode", "gatesDigest", "contractDigest", "itemsDigest"]
# The owner preference blocks tonight's snapshot freezes. A block the snapshot does not carry
# emits its type and no fields, which is how a policy written before this feature is told apart
# from one whose owner left a block empty.
PREF = [("shift", ["copyIn", "execution", "hours", "isolation", "itemBudget", "prepare", "toolingPolicy", "verificationProfile", "worktreeRoot"]),
        ("recovery", ["launchScope"]),
        ("handoff", ["detail", "enabled", "language", "sections", "templatePath", "view"]),
        ("archive", ["automatic", "layout", "root", "templatePath"]),
        ("receipts", ["duration", "enabled", "evidence.architecture", "evidence.check",
                    "evidence.default", "evidence.fileMap", "evidence.review", "evidence.unavailable",
                    "progressMinutes", "progressMode", "progressTokens", "templatePath", "usage"]),
        ("catalogs", ["edge-cases.paths", "edge-cases.template", "evidence.paths", "evidence.template",
                      "gates.paths", "gates.template", "shifts.paths", "shifts.template"])]
out = []


def enc(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def scrub(s):
    return re.sub(r"[\x00-\x1f\x7f]", " ", s)


def norm(s):
    return re.sub(r"[ \t\n\x0b\f\r]+", " ", s).strip(" ")


def kind(v):
    if v is None:
        return "null"
    if v is True or v is False:
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    return "invalid"


def obj(v):
    return v if isinstance(v, dict) else {}


def arr(v):
    return v if isinstance(v, list) else []


def jn(p, k):
    return k if p == "." else p + "." + k


def ty(p, v):
    out.append("ty\t%s\t%s" % (p, kind(v)))


def ks(p, v):
    if isinstance(v, dict):
        for k in v:
            out.append("k\t%s\t%s" % (p, scrub(k)))


def dig(v, k):
    for part in k.split("."):
        v = obj(v).get(part)
    return v


def sc(p, v, names):
    for k in names:
        out.append("j\t%s\t%s" % (jn(p, k), enc(dig(v, k))))


def cnt(p, v):
    out.append("n\t%s\t%s" % (p, len(v) if isinstance(v, list) else -1))


try:
    P = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(P, dict):
    sys.stdout.write("x\t.\tnotobject\n")
    sys.exit(0)
ks(".", P)
sc(".", P, SCALARS)
for block, fields in PREF:
    ty(block, P.get(block))
    if block in P:
        sc(block, P.get(block), fields)
ty("budgets", P.get("budgets"))
for key, value in obj(P.get("budgets")).items():
    out.append("b\t%s\t%s" % (scrub(key), enc(value)))
ty("selectedDebt", P.get("selectedDebt"))
cnt("selectedDebt", P.get("selectedDebt"))
for i, one in enumerate(arr(P.get("selectedDebt"))):
    out.append("s\t%d\t%s\t%s" % (i, "s" if isinstance(one, str) else "x", enc(one)))
ty("allowances", P.get("allowances"))
cnt("allowances", P.get("allowances"))
for i, a in enumerate(arr(P.get("allowances"))):
    ap = "allowances[%d]" % i
    ty(ap, a)
    ks(ap, a)
    sc(ap, a, ["category", "scope", "provenance"])
    plan = obj(a).get("plan")
    ty(jn(ap, "plan"), plan)
    ks(jn(ap, "plan"), obj(plan))
    sc(jn(ap, "plan"), obj(plan), ["workTarget", "digest", "expiry"])
    cs = obj(plan).get("commands")
    ty(jn(ap, "plan.commands"), cs)
    cnt(jn(ap, "plan.commands"), cs)
    for n, one in enumerate(arr(cs)):
        ok = isinstance(one, str)
        out.append("c\t%d\t%d\t%s\t%s" % (i, n, "s" if ok else "x", norm(one) if ok else ""))
        out.append("q\t%d\t%d\t%s" % (i, n, enc(norm(one)) if ok else "null"))
    ws = obj(plan).get("writeSurface")
    ty(jn(ap, "plan.writeSurface"), ws)
    for n, one in enumerate(arr(ws)):
        out.append("w\t%d\t%d\t%s" % (i, n, "s" if isinstance(one, str) else "x"))
sys.stdout.write("".join(line + "\n" for line in out))
