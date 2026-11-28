    /^---[[:space:]]*$/ { seen=1; next }
    seen && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ { n++ }
    END { print n+0 }
  
