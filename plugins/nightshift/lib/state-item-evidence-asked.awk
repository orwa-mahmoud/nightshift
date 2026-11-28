    /^- \[[ xX-]\]/ { inside = (ns_item_label($0) == want); next }
    /^[^[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]+-[[:space:]]+Evidence:/ { found = 1; exit }
    END { exit !found }
  
