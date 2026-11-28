    /^- \[[xX-]\]/ {
      n++
      line = ns_item_label($0)
      if (line == "") line = "item " n
      print line
    }
  
