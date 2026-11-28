    /^- \[[ xX-]\]/ { inside = (ns_item_label($0) == want); next }
    /^[^[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]+-[[:space:]]+Evidence:/ {
      sub(/^[[:space:]]+-[[:space:]]+Evidence:[[:space:]]*/, "")
      print
      exit
    }
  
