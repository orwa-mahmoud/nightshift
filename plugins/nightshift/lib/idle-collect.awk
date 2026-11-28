    { pid = $1 + 0; ppid = $2 + 0; parent[pid] = ppid; seen[pid] = 1 }
    END {
      if (!seen[root]) exit
      q[1] = root; n = 1; walk[root] = 1
      for (i = 1; i <= n; i++) {
        print q[i]
        for (c in parent) if (parent[c] == q[i] && !walk[c]) { walk[c] = 1; q[++n] = c }
      }
    }
  
