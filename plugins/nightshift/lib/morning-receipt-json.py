import json, re, sys

OP = sys.argv[1]


def scrub(s):
    return re.sub(r"[\x00-\x1f\x7f]", " ", s)


def canon(v):
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def cell(v):
    if v is None:
        text = ""
    elif isinstance(v, str):
        text = v
    elif v is True:
        text = "true"
    elif v is False:
        text = "false"
    else:
        text = canon(v)
    return scrub(text)


def field(rec, key):
    return rec.get(key) if isinstance(rec, dict) else None


def firstof(rec, keys):
    for key in keys:
        value = field(rec, key)
        if value is not None:
            return value
    return None


def parse(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
out = sys.stdout

if OP == "recs":
    fields = [x for x in sys.argv[2].split("\n") if x]
    FS, RS = sys.argv[3], sys.argv[4]
    for i, line in enumerate([x for x in text.split("\n") if x]):
        rec = parse(line)
        if isinstance(rec, dict):
            out.write("r" + FS + "".join(cell(field(rec, k)) + FS for k in fields))
        else:
            out.write("u" + FS + "".join("" + FS for k in fields))
        out.write(str(i) + RS)
elif OP == "details":
    FS, RS = sys.argv[2], sys.argv[3]
    for i, line in enumerate([x for x in text.split("\n") if x]):
        d = field(parse(line), "details")
        if not isinstance(d, dict):
            continue
        for key in sorted(d):
            out.write("%d%s%s%s%s%s" % (i, FS, scrub(key), FS, cell(d[key]), RS))
elif OP == "policy":
    FS, RS = sys.argv[2], sys.argv[3]
    doc = json.loads(text)
    if not isinstance(doc, dict):
        doc = {}
    head = ["shiftId", "createdAt", "source", "verificationLevel", "toolingPolicy",
            "completionMode"]
    debt = field(doc, "selectedDebt")
    if not isinstance(debt, list):
        debt = []
    out.write("h" + FS + "".join(cell(field(doc, k)) + FS for k in head))
    out.write(", ".join(cell(x) for x in debt) + RS)
    allowances = field(doc, "allowances")
    if not isinstance(allowances, list):
        allowances = []
    for one in allowances:
        if not isinstance(one, dict):
            continue
        out.write("a" + FS + cell(field(one, "category")) + FS + cell(field(one, "scope"))
                  + FS + cell(field(one, "provenance")) + RS)
elif OP == "compare":
    FS, RS = sys.argv[2], sys.argv[3]
    doc = json.loads(text)
    rows = None
    if isinstance(doc, list):
        rows = doc
    elif isinstance(doc, dict):
        for key in ("rows", "findings", "comparison", "entries"):
            if isinstance(doc.get(key), list):
                rows = doc[key]
                break
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        sources = firstof(row, ["sources", "sourceClass", "source"])
        if isinstance(sources, list):
            sources = ", ".join(cell(x) for x in sources)
        else:
            sources = cell(sources)
        out.write(cell(firstof(row, ["id", "finding", "recordId"])) + FS
                  + cell(firstof(row, ["class", "classification", "state"])) + FS
                  + cell(firstof(row, ["digest"])) + FS + sources + FS
                  + cell(firstof(row, ["locator", "at"])) + RS)
