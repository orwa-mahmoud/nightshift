# The usage blocks a receipt carried before it kept one section: one block per tick, each inserted
# above the one before, so the newest comes first.
#
# A block opens at a Tokens table or a `**Tokens:** off` line and holds the raw-token comment, the
# host line and the Time table that follow it. Whether two blocks overlap is read from their spans:
# a newer block whose span holds an older one's span already counts it (the readings ran on), and
# an older block whose span lies outside every newer one is a session of its own (the readings were
# set aside between them). A block with no span counts only when it is the newest.
#
# Text inside the runtime section or a Sessions block is not a legacy block and is skipped.
#
# Prints one line per counted block, oldest first:
#   <span-start>\t<span-end>\t<working>\t<paused>\t<tokens>\t<time-off>\t<hosts>
# where <tokens> is the five raw figures or `off`, the times are as written, <hosts> is the host
# line's `host model; host model` part, and an empty field is `-` so no column collapses.

/^<!-- usage -->/ { inside = 1; next }
/^<!-- \/usage -->/ { inside = 0; next }
/^<!-- sessions -->/ { inside = 1; next }
/^<!-- \/sessions -->/ { inside = 0; next }
inside { next }

{ line = $0; sub(/\r$/, "", line) }

line == "| Tokens | Amount |" || line == "**Tokens:** off" {
  n++
  tok[n] = (line == "**Tokens:** off") ? "off" : ""
  next
}

n && line ~ /^<!-- tokens [0-9 ]+-->$/ {
  t = line
  sub(/^<!-- tokens /, "", t)
  sub(/ *-->$/, "", t)
  tok[n] = t
  next
}

n && line ~ / · [0-9]+ segments?\./ {
  h = line
  sub(/ · [0-9]+ segments?\..*$/, "", h)
  host[n] = h
  next
}

n && line == "**Time:** off" { timeoff[n] = 1; next }

n && line ~ /^\| working \| / {
  w = line
  sub(/^\| working \| */, "", w)
  sub(/ *\|$/, "", w)
  work[n] = w
  next
}

n && line ~ /^\| paused \| / {
  p = line
  sub(/^\| paused \| */, "", p)
  sub(/ *\(.*$/, "", p)
  sub(/ *\|$/, "", p)
  pause[n] = p
  next
}

n && line ~ /^\| span \| .* → .* \|$/ {
  s = line
  sub(/^\| span \| */, "", s)
  sub(/ *\|$/, "", s)
  split(s, ends, / → /)
  from[n] = ends[1]
  to[n] = ends[2]
  next
}

function value_or_dash(v) { return v == "" ? "-" : v }

END {
  for (i = n; i >= 1; i--) {
    if (tok[i] == "" && !timeoff[i] && work[i] == "") continue
    counted = 1
    if (from[i] == "") {
      counted = (i == 1)
    } else {
      for (j = 1; j < i; j++) {
        if (from[j] != "" && from[j] <= from[i] && to[j] >= to[i]) {
          counted = 0
          break
        }
      }
    }
    if (!counted) continue
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", value_or_dash(from[i]), value_or_dash(to[i]), value_or_dash(work[i]), value_or_dash(pause[i]), value_or_dash(tok[i]), timeoff[i] ? 1 : 0, value_or_dash(host[i])
  }
}
