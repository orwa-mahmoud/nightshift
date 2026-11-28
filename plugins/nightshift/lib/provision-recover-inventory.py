import json, sys
recipe_path, now, cap, setup, base_text = sys.argv[1:6]
r = json.load(open(recipe_path))
if not isinstance(r, dict):
    raise SystemExit(1)
smoke = r.get("smoke")
command = ""
if isinstance(smoke, dict):
    command = smoke.get("command") or smoke.get("cmd") or ""
elif isinstance(smoke, str):
    command = smoke
allowed = r.get("allowedFiles")
if not isinstance(allowed, list):
    allowed = []
item = {"capability": cap, "command": command, "source": "recipe", "verifiedAt": now,
        "configFiles": list(allowed), "recipeVersion": r.get("recipeVersion"),
        "setupCommit": setup}
doc = json.loads(base_text)
if not isinstance(doc, dict):
    doc = {"items": []}
items = doc.get("items")
if not isinstance(items, list):
    items = []
doc["items"] = [i for i in items if isinstance(i, dict) and i.get("capability") != cap] + [item]
doc["schemaVersion"] = 1
doc["updatedAt"] = now
doc["tickProof"] = False
sys.stdout.write(json.dumps(doc, indent=2, sort_keys=True))
