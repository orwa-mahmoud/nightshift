    { line = $0; sub(/\r$/, "", line) }
    !items { if (mode == "closed") print; if (line ~ /^## Items[[:space:]]*$/) items = 1; next }
    done { if (mode == "closed") print; next }
    line ~ /^## / { if (mode == "closed") { printf "%s", blanks; print } blanks = ""; done = 1; next }
    line == "" { blanks = blanks $0 "\n"; next }
    line ~ /^- \[[ xX-]\]/ {
      take = (line ~ /^- \[[xX]\]/)
      if (take) { if (mode == "closed") printf "%s", blanks; print }
      blanks = ""
      next
    }
    line ~ /^[[:space:]]/ { if (take) { printf "%s", blanks; print } blanks = ""; next }
    { take = 0; if (mode == "closed") { printf "%s", blanks; print } blanks = "" }
    END { if (mode == "closed") printf "%s", blanks }
  
