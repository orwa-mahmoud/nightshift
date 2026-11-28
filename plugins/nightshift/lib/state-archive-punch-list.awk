    { line = $0; sub(/\r$/, "", line) }
    !items { print; if (line ~ /^## Items[[:space:]]*$/) items = 1; next }
    done { print; next }
    line ~ /^## / { printf "%s", blanks; blanks = ""; done = 1; print; next }
    line == "" { blanks = blanks $0 "\n"; next }
    line ~ /^- \[[xX]\]/ { drop = 1; blanks = ""; next }
    line ~ /^[[:space:]]/ { if (!drop) { printf "%s", blanks; print } blanks = ""; next }
    { drop = 0; printf "%s", blanks; blanks = ""; print }
    END { if (!drop) printf "%s", blanks }
  
