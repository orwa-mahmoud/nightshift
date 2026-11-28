import json, sys
sys.stdout.write(json.dumps(sys.stdin.read(), ensure_ascii=False))
