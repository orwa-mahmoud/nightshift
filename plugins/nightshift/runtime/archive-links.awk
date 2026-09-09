# Repoint one record's own links when it is filed into the archive.
#
# The record sits beside the live records it links to. Filed into archive/<date>/ it no longer
# does: a record that travelled with it is still a sibling, but one that stayed live — a parking
# decision nobody has answered, the receipt of an item nobody finished — is now several
# directories away. Copying the bytes unchanged leaves those links pointing at files that do not
# exist.
#
#   NS_ARCHIVED_PATHS  newline-separated record paths, relative to the state directory, that moved
#                      into the archive alongside this record; their relative links already
#                      resolve. Passed in the environment because awk's -v rejects a newline.
#   dir                the record's own directory before the move, relative to the state
#                      directory. Empty for a record that sat at the top of it. Every relative
#                      link was written against this directory, so this is what they resolve
#                      against — a bare `name` or `./name` names a file that sat right beside it.
#   back               the relative path from the archive directory back to the state directory.
#
# Only inline links and reference definitions whose target is a relative path are touched. A
# scheme, a leading slash and a bare fragment are left exactly as written, as is everything inside
# a fenced code block: raw evidence is evidence.
#
# A link that climbs with ../ is rebased like any other. It was written relative to the record's
# own directory, and the record has moved deeper — so a project deliverable two levels out of the
# state directory is that much further away now, and leaving it alone breaks it.
BEGIN {
  n = split(ENVIRON["NS_ARCHIVED_PATHS"], list, "\n")
  for (i = 1; i <= n; i++) {
    if (list[i] != "") moved[list[i]] = 1
  }
  if (back != "" && substr(back, length(back)) != "/") back = back "/"
  if (dir != "" && substr(dir, length(dir)) == "/") dir = substr(dir, 1, length(dir) - 1)
  fence = 0
}

# Where a relative link points, as a path relative to the state directory. It was written against
# the record's own directory, so that is what it resolves against; ../ that climbs out of the state
# area is kept, because back/ lands at the top of it before the climb starts.
function resolve(path,   parts, n, i, m, seg, out, joined) {
  joined = (dir == "" ? path : dir "/" path)
  n = split(joined, parts, "/")
  m = 0
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == ".." && m > 0 && out[m] != "..") { m--; continue }
    out[++m] = seg
  }
  joined = ""
  for (i = 1; i <= m; i++) joined = (joined == "" ? out[i] : joined "/" out[i])
  return joined
}

function repoint(target,   path, frag, hash, rel) {
  hash = index(target, "#")
  if (hash > 0) {
    path = substr(target, 1, hash - 1)
    frag = substr(target, hash)
  } else {
    path = target
    frag = ""
  }
  if (path == "") return target
  if (path ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return target
  if (path ~ /^\//) return target
  if (path in moved) return target
  rel = resolve(path)
  if (rel == "") return target
  # The file it names travelled here too: still a sibling, still reached exactly as written.
  if (rel in moved) return target
  return back rel frag
}

# One line of Markdown with every eligible inline link repointed. Scanned character by character
# rather than substituted by pattern, so a code span or a stray bracket cannot make it rewrite
# something that is not a link.
function rewrite(line,   out, i, len, ch, depth, target, stop, tick) {
  out = ""
  len = length(line)
  i = 1
  while (i <= len) {
    ch = substr(line, i, 1)
    if (ch == "`") {
      tick = i + 1
      while (tick <= len && substr(line, tick, 1) != "`") tick++
      out = out substr(line, i, tick - i + 1)
      i = tick + 1
      continue
    }
    if (ch == "]" && substr(line, i + 1, 1) == "(") {
      depth = 1
      stop = i + 2
      while (stop <= len && depth > 0) {
        if (substr(line, stop, 1) == "(") depth++
        else if (substr(line, stop, 1) == ")") depth--
        if (depth == 0) break
        stop++
      }
      if (depth == 0) {
        target = substr(line, i + 2, stop - i - 2)
        out = out "](" repoint(target) ")"
        i = stop + 1
        continue
      }
    }
    out = out ch
    i++
  }
  return out
}

{
  if ($0 ~ /^[[:space:]]*(```|~~~)/) {
    fence = !fence
    print
    next
  }
  if (fence) {
    print
    next
  }
  # A reference definition: [label]: target "optional title"
  if ($0 ~ /^[[:space:]]*\[[^]]*\]:[[:space:]]*[^[:space:]]/) {
    head = $0
    sub(/\]:[[:space:]]*.*$/, "]: ", head)
    rest = $0
    sub(/^[[:space:]]*\[[^]]*\]:[[:space:]]*/, "", rest)
    tail = ""
    if (match(rest, /[[:space:]]/)) {
      tail = substr(rest, RSTART)
      rest = substr(rest, 1, RSTART - 1)
    }
    print head repoint(rest) tail
    next
  }
  print rewrite($0)
}
