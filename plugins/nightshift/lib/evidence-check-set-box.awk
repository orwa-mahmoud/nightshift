    /^- \[[ xX-]\]/ {
      if (ns_item_label($0) == want) sub(/^- \[[ xX-]\]/, "- [" mark "]")
    }
    { print }
  
