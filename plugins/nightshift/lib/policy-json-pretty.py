import json, sys
sys.stdout.write(json.dumps(json.load(sys.stdin), sort_keys=True, indent=2) + "\n")
