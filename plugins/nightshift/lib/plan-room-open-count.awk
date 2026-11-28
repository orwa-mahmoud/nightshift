    /^## Items[[:space:]]*$/ { items = 1; next }
    /^## / { items = 0 }
    items && /^- \[ \]/ { n++ }
    END { print n + 0 }
  
