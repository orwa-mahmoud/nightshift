    function flush() {
      if (key == "") return
      sub(/(\037[[:space:]]*)+$/, "", text)
      printf "item\t%s\t%s\t%s\n", key, label, text
    }
    /^- \[[ xX-]\]/ {
      flush()
      label = ns_item_label($0)
      key = ns_item_id($0)
      if (key == "") key = label
      gsub(/\t/, " ", label)
      text = $0
      sub(/[[:space:]]*<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/, "", text)
      gsub(/\t/, " ", text)
      next
    }
    key != "" { line = $0; gsub(/\t/, " ", line); text = text "\037" line }
    END { flush() }
  
