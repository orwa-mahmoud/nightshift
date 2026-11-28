import json, sys

FREEFORM = {"forbiddenCommands", "protectedDirs", "neverCommitPatterns", "expectedEmail"}
d = json.load(sys.stdin)["settings"]
for k in sorted(d):
    v = d[k]["value"]
    text = v if isinstance(v, str) else json.dumps(v)
    shown = text
    if k in FREEFORM or len(text) > 80:
        shown = "<redacted %d chars>" % len(text)
    sys.stdout.write("%s=%s (%s, %s)\n" % (k, shown, d[k]["source"], d[k]["expiry"]))
