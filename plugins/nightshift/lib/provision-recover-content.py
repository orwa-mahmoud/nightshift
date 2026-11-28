import base64, json, sys
d = json.load(open(sys.argv[1]))
b = d.get("baseline")
if not isinstance(b, dict):
    b = {}
v = b.get(sys.argv[2])
if not isinstance(v, dict):
    v = {}
c = v.get("content")
if not isinstance(c, str):
    c = ""
sys.stdout.buffer.write(base64.b64decode(c.encode("ascii")))
