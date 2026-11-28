    { sub(/\r$/, "") }
    !on { if ($0 ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; next }
    /^## / { exit }
    { print }
  
