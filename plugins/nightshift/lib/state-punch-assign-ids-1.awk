    { line = $0; sub(/\r$/, "", line) }
    !on { if (line ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; next }
    line ~ /^## / { exit }
    line ~ /^- \[[ xX-]\]/ && ns_item_id(line) == "" { n++ }
    END { print n + 0 }
  
