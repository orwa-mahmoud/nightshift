import json, sys
f = o = b = c = 0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        f += 1
        if rec.get("domain") == "baseline":
            b += 1
        elif rec.get("domain") == "checkpoint":
            c += 1
        if rec.get("status") == "open":
            o += 1
print(f"{f} {o} {b} {c}")
