    function centi(raw,   t, n, a, h, m, rest, s, frac) {
      t = raw
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      sub(/^[0-9]+-/, "", t)
      if (t !~ /^[0-9][0-9:.]*$/) return -1
      n = split(t, a, ":")
      h = 0; m = 0
      if (n == 3) { h = a[1]; m = a[2]; rest = a[3] }
      else if (n == 2) { m = a[1]; rest = a[2] }
      else rest = a[1]
      s = rest; sub(/\..*/, "", s)
      frac = 0
      if (rest ~ /\./) {
        frac = rest; sub(/.*\./, "", frac); frac = substr(frac "00", 1, 2) + 0
      }
      return h * 360000 + m * 6000 + s * 100 + frac
    }
    {
      pid = $1 + 0; ppid = $2 + 0
      parent[pid] = ppid
      cpus[pid] = centi($3)
      base = $4
      sub(/.*\//, "", base)
      name[pid] = base
      seen[pid] = 1
    }
    END {
      nroots = split(roots, r, " ")
      cpu = 0; busy = 0; known = 1; qn = 0
      for (k = 1; k <= nroots; k++) {
        root = r[k] + 0
        if (root == 0) continue
        if (!seen[root]) { known = 0; continue }
        if (walk[root]) continue
        q[++qn] = root; walk[root] = 1
      }
      if (qn == 0) { print "0\t0\t0"; exit }
      for (i = 1; i <= qn; i++) {
        p = q[i]
        if (cpus[p] < 0) known = 0
        else cpu += cpus[p]
        if (name[p] ~ work) busy = 1
        for (c in parent) if (parent[c] == p && !walk[c]) {
          walk[c] = 1; q[++qn] = c
        }
      }
      print cpu "\t" known "\t" busy
    }
  
