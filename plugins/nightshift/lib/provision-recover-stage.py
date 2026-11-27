import json, sys
d = json.load(open(sys.argv[1]))
d["stage"] = "commit-tooling"
d["updatedAt"] = sys.argv[2]
sys.stdout.write(json.dumps(d, indent=2, sort_keys=True))
