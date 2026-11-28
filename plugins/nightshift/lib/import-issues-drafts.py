import re, sys

ITEM_RE = re.compile(r"(?m)^- \[ \] \*\*.+\*\*\s*$")
SOURCE_RE = re.compile(
    r"(?m)^\s*- Source: (https://github.com/[^/\s]+/[^/\s]+/issues/\d+)\s*$"
)
STATUS_RE = re.compile(r"(?m)^\s*- Status: proposed\s*$")
REPO_RE = re.compile(r"(?m)^\s*- Repository: (\S+)\s*$")
FLAGS_RE = re.compile(r"(?m)^\s*- Review flags: (.+?)\s*$")
TITLE_RE = re.compile(r"^- \[ \] \*\*(.+)\.\*\*\s*$")

def split_items(text):
    matches = list(ITEM_RE.finditer(text))
    if not matches:
        return text, []
    head = text[: matches[0].start()]
    items = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        items.append(text[m.start() : end])
    return head, items

def parse_import(block):
    if not STATUS_RE.search(block):
        return None
    sm = SOURCE_RE.search(block)
    if not sm:
        return None
    rm = REPO_RE.search(block)
    fm = FLAGS_RE.search(block)
    first = block.splitlines()[0] if block.splitlines() else ""
    tm = TITLE_RE.search(first)
    return {
        "block": block,
        "url": sm.group(1),
        "repo": rm.group(1) if rm else "",
        "flags": fm.group(1).strip() if fm else "none",
        "title": tm.group(1) if tm else "",
    }

def load_imports(path):
    text = open(path, encoding="utf-8").read()
    head, items = split_items(text)
    parsed = []
    other = []
    for block in items:
        info = parse_import(block)
        if info:
            parsed.append(info)
        else:
            other.append(block)
    return text, head, parsed, other

cmd, draft_path = sys.argv[1], sys.argv[2]
auth = sys.argv[3] if len(sys.argv) > 3 else ""
_, head, imported, other = load_imports(draft_path)

def allowed(info):
    return not auth or info["repo"] == auth

if cmd == "list":
    for info in imported:
        if allowed(info):
            print("\t".join([info["url"], info["repo"], info["flags"], info["title"]]))
    sys.exit(0)

if cmd != "promote":
    sys.exit(2)

punch_path = sys.argv[4]
allow_flagged = sys.argv[5] == "1"
urls = sys.argv[6:]
punch = open(punch_path, encoding="utf-8").read()
if "## Items" not in punch:
    sys.stderr.write("import-issues: punch list has no ## Items heading\n")
    sys.exit(2)

by_url = {info["url"]: info for info in imported}
chosen = []
for url in urls:
    info = by_url.get(url)
    if info is None:
        sys.stderr.write("import-issues: not a proposed imported issue: %s\n" % url)
        sys.exit(2)
    if not allowed(info):
        sys.stderr.write("import-issues: %s is outside the authorized repository\n" % url)
        sys.exit(2)
    if info["flags"] != "none" and not allow_flagged:
        sys.stderr.write("import-issues: refuse flagged issue %s (%s)\n" % (url, info["flags"]))
        sys.exit(2)
    if info["url"] in punch:
        sys.stderr.write("import-issues: already on the punch list: %s\n" % url)
        sys.exit(2)
    chosen.append(info)

if not chosen:
    sys.stderr.write("import-issues: nothing to promote\n")
    sys.exit(1)

remain = [info["block"] for info in imported if info["url"] not in {c["url"] for c in chosen}]
new_draft = head + "".join(other) + "".join(remain)
moved = "".join(c["block"].rstrip() + "\n\n" for c in chosen)
if not punch.endswith("\n"):
    punch += "\n"
new_punch = punch + "\n" + moved
open(draft_path + ".next", "w", encoding="utf-8").write(new_draft)
open(punch_path + ".next", "w", encoding="utf-8").write(new_punch)
print("promoted\t%d" % len(chosen))
