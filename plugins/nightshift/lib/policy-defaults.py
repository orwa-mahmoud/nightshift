import json, sys

K = ["schemaVersion", "verificationProfile", "hours", "toolingPolicy", "execution", "updatedAt"]
try:
    D = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(D, dict):
    sys.stdout.write("x\t.\tnotobject\n")
    sys.exit(0)
sys.stdout.write("".join(
    "d\t%s\t%s\t%s\n" % (k, "1" if k in D else "0",
                         json.dumps(D.get(k), ensure_ascii=False, separators=(",", ":")))
    for k in K))
