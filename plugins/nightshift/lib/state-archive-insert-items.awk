    function put(   l) { while ((getline l <add) > 0) print l; close(add); added = 1 }
    { line = $0; sub(/\r$/, "", line) }
    !items { print; if (line ~ /^## Items[[:space:]]*$/) items = 1; next }
    added { print; next }
    line ~ /^## / { put(); printf "%s", blanks; blanks = ""; print; next }
    line == "" { blanks = blanks $0 "\n"; next }
    { printf "%s", blanks; blanks = ""; print }
    END { if (!added) put(); printf "%s", blanks }
  
