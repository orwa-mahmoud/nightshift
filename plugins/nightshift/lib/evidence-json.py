import json, sys

OP = sys.argv[1]


def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"))


def names(s):
    return [x for x in s.split("\n") if x]


def tname(v):
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
    return "object"


def presence(rec, keys):
    return "".join("1" if isinstance(rec, dict) and k in rec else "0" for k in keys)


def field(rec, key):
    return rec.get(key) if isinstance(rec, dict) else None


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()
out = []

if OP == "canon":
    try:
        sys.stdout.write(canon(json.loads(text)) + "\n")
    except ValueError:
        sys.exit(1)
elif OP == "check":
    for line in lines:
        try:
            json.loads(line)
            out.append("1")
        except ValueError:
            out.append("0")
elif OP == "canonlines":
    for line in lines:
        out.append(canon(json.loads(line)))
elif OP == "tojson":
    sys.stdout.write(canon(text))
elif OP == "schema":
    doc = json.loads(text)
    for key in doc["required"]:
        out.append("R\t" + key)
    for tag, name in (
        ("S", "severity"),
        ("C", "confidence"),
        ("I", "impact"),
        ("T", "status"),
        ("L", "ladder"),
    ):
        for value in doc[name]:
            out.append(tag + "\t" + canon(value))
elif OP == "facts":
    req, hkeys, fields, sep = (
        names(sys.argv[2]),
        names(sys.argv[3]),
        names(sys.argv[4]),
        sys.argv[5],
    )
    for i, line in enumerate(lines):
        rec = json.loads(line)
        head = sep + str(i) + sep
        out.append("t" + head + tname(rec))
        out.append("q" + head + presence(rec, req))
        out.append("h" + head + presence(rec, hkeys))
        out.append("s" + head + ("1" if field(rec, "schemaVersion") == 1 else "0"))
        for slot, key in enumerate(fields):
            out.append("v" + head + str(slot) + sep + canon(field(rec, key)))
elif OP == "rows":
    cols, sep, term = names(sys.argv[2]), sys.argv[3], sys.argv[4]
    for line in lines:
        rec = json.loads(line)
        row = "".join(str(field(rec, c)) + sep for c in cols)
        sys.stdout.write(row + presence(rec, cols) + term)
elif OP == "edit":
    assign, sep, term = sys.argv[2], sys.argv[3], sys.argv[4]
    rec = json.loads(text)
    for one in assign.split(term):
        if not one:
            continue
        f = one.split(sep)
        if f[1] == "s":
            rec[f[0]] = f[2]
        elif f[1] == "n":
            rec[f[0]] = json.loads(f[2])
        else:
            rec[f[0]] = rec[f[2]]
    sys.stdout.write(canon(rec) + "\n")

if out:
    sys.stdout.write("".join(line + "\n" for line in out))
