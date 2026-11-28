import json, sys
last = ""
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("domain") == "checkpoint" and rec.get("id"):
            last = rec["id"]
print(last)
