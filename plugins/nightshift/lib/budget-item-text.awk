    /^- \[[ xX-]\]/ { inside = (ns_item_label($0) == want); next }
    /^[^[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]+-[[:space:]]+Budget:/ {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]+-[[:space:]]+Budget:[[:space:]]*/, "", line)
      print line
      exit
    }
  
