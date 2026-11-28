    { sub(/\r$/, "") }
    /^## Items[[:space:]]*$/ { exit }
    /^## Gates[[:space:]]*$/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }
  
