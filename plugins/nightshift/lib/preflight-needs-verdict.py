import json, sys

d = json.load(sys.stdin)["settings"]
for k in sorted(d):
    if k.startswith("elevation."):
        v = d[k]["value"]
        sys.stdout.write("%s\t%s\n" % (k[len("elevation."):], v))
