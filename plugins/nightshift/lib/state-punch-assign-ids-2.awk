    BEGIN { split(ids, pool, " "); k = 0 }
    { line = $0; cr = ""; if (sub(/\r$/, "", line)) cr = "\r" }
    !on { if (line ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; print; next }
    line ~ /^## / { on = 0; done = 1 }
    !done && line ~ /^- \[[ xX-]\]/ && ns_item_id(line) == "" {
      k++
      print line " <!-- id: " pool[k] " -->" cr
      next
    }
    { print }
  
