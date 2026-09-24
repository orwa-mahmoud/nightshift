# Repoint the relative links of one Markdown file for the state layout it is moving into.
#
# A link was written against the directory its file sat in. After migrate-state the file may sit
# elsewhere, and so may what it names; a link that still resolves is left exactly as written, and
# one that no longer does is read against the directory the file used to sit in, carried through
# the moves, and written again relative to where the file sits now. Reading it again after that
# finds nothing to change, which is what lets an interrupted run be finished by running it again.
#
#   NS_MIG_EXISTS  newline-separated paths, relative to the state directory, that exist once every
#                  move is made. Passed in the environment because awk's -v rejects a newline.
#   NS_MIG_MOVES   newline-separated `old<TAB>new` pairs; a directory carries everything beneath it.
#   NS_MIG_ROOT    the state directory, for a link that climbs out of it: that one is checked on
#                  disk, since nothing outside the state directory moves.
#   dir            the directory the file sits in once the moves are made, relative to the state
#                  directory; empty for the top of it.
#   olddirs        tab-separated directories the file may have sat in when its links were written.
#   mode           `plan` prints `old<TAB>new` for each link it would change; `apply` prints the
#                  file with those links changed; `canon` prints it with every relative link
#                  written as the state path it names once each file is in its current place, so
#                  two copies of a file written from different directories compare equal.
#
# Only inline links and reference definitions with a relative target are read. A scheme, a leading
# slash and a bare fragment are left as written, as is everything inside a fenced code block.
BEGIN {
  n = split(ENVIRON["NS_MIG_EXISTS"], list, "\n")
  for (k = 1; k <= n; k++) if (list[k] != "") present[list[k]] = 1
  m = split(ENVIRON["NS_MIG_MOVES"], pairs, "\n")
  for (k = 1; k <= m; k++) {
    if (pairs[k] == "") continue
    split(pairs[k], pr, "\t")
    moves[pr[1]] = pr[2]
  }
  root = ENVIRON["NS_MIG_ROOT"]
  if (dir != "" && substr(dir, length(dir)) == "/") dir = substr(dir, 1, length(dir) - 1)
  # The first directory is the one the file sits in, which is the top of the state directory when
  # it is empty; split() would count an empty list as no directory at all.
  nold = split(olddirs, olds, "\t")
  if (nold == 0) {
    nold = 1
    olds[1] = ""
  }
  fence = 0
}

# A path relative to the state directory, from a link written against <base>.
function resolve(base, path,   parts, count, j, top, seg, out, joined) {
  joined = (base == "" ? path : base "/" path)
  count = split(joined, parts, "/")
  top = 0
  for (j = 1; j <= count; j++) {
    seg = parts[j]
    if (seg == "" || seg == ".") continue
    if (seg == ".." && top > 0 && out[top] != "..") { top--; continue }
    out[++top] = seg
  }
  joined = ""
  for (j = 1; j <= top; j++) joined = (joined == "" ? out[j] : joined "/" out[j])
  return joined
}

# Where a path is once the moves are made: itself, or the new home of it or of a directory above it.
function carried(p,   q, cut) {
  if (p in moves) return moves[p]
  q = p
  while ((cut = last_slash(q)) > 0) {
    q = substr(q, 1, cut - 1)
    if (q in moves) return moves[q] substr(p, length(q) + 1)
  }
  return p
}

function last_slash(s,   k) {
  for (k = length(s); k > 0; k--) if (substr(s, k, 1) == "/") return k
  return 0
}

function quoted(s) {
  gsub(/'/, "'\\''", s)
  return "'" s "'"
}

function exists(p) {
  if (p == "") return 1
  if (substr(p, 1, 3) == "../" || p == "..") return (system("test -e " quoted(root "/" p)) == 0)
  return (p in present)
}

# <to> relative to <from>, both relative to the state directory; <to> may climb out of it.
function relative(from, to,   fp, tp, fc, tc, j, common, out) {
  fc = (from == "" ? 0 : split(from, fp, "/"))
  tc = split(to, tp, "/")
  common = 0
  while (common < fc && common < tc && fp[common + 1] == tp[common + 1] && tp[common + 1] != "..") common++
  out = ""
  for (j = common + 1; j <= fc; j++) out = out "../"
  for (j = common + 1; j <= tc; j++) out = out tp[j] (j < tc ? "/" : "")
  return out
}

function repoint(target,   hash, path, frag, slash, here, j, then, now) {
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
  slash = ""
  if (substr(path, length(path)) == "/") {
    slash = "/"
    path = substr(path, 1, length(path) - 1)
  }
  if (mode == "canon") return carried(resolve(dir, path)) slash frag
  here = resolve(dir, path)
  if (exists(here)) return target
  # Read against each directory the file may have been written in, the one it sits in first: a
  # file that stayed put may still name one that moved.
  for (j = 1; j <= nold; j++) {
    then = resolve(olds[j], path)
    now = carried(then)
    if (exists(now)) {
      if (mode == "plan") printf "%s\t%s\n", target, relative(dir, now) slash frag
      return relative(dir, now) slash frag
    }
  }
  return target
}

# One line with every eligible inline link repointed. Scanned character by character rather than
# substituted by pattern, so a code span or a stray bracket cannot make it rewrite something that
# is not a link.
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

function emit(s) {
  if (mode == "apply" || mode == "canon") print s
}

{
  if ($0 ~ /^[[:space:]]*(```|~~~)/) {
    fence = !fence
    emit($0)
    next
  }
  if (fence) {
    emit($0)
    next
  }
  # A reference definition: [label]: target "optional title"
  if ($0 ~ /^[ \t]*\[[^]]*\]:[ \t]*[^ \t]/) {
    match($0, /^[ \t]*\[[^]]*\]:[ \t]*/)
    head = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    tail = ""
    if (match(rest, /[[:space:]]/)) {
      tail = substr(rest, RSTART)
      rest = substr(rest, 1, RSTART - 1)
    }
    emit(head repoint(rest) tail)
    next
  }
  emit(rewrite($0))
}
