import json, sys
for line in sys.stdin.read().split("\n")[:-1]:
    sys.stdout.write(json.dumps(line, ensure_ascii=False) + "\n")
