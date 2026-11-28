import json, sys
sys.stdout.write(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")) + "\n")
