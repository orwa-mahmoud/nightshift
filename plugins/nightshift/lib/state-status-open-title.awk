    NR == 1 {
      sub(/[[:space:]]*<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/, "")
      sub(/^- \[[ xX-]\][[:space:]]*/, "")
      gsub(/\*\*/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  
