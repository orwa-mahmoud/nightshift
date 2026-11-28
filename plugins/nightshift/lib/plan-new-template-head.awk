    NR == 1 { next }
    /^## Items[[:space:]]*$/ { exit }
    { print }
  
