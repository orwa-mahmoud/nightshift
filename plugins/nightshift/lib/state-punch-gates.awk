    /^## Gates[[:space:]]*$/ { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  
