    /^- \[[ xX-]\]/ {
      state = ($0 ~ /^- \[ \]/) ? "open" : ($0 ~ /^- \[-\]/) ? "stopped" : "ticked"
      if (want != "all" && want != state) next
      label = ns_item_label($0)
      if (label != "") print label "\t" ns_item_id($0)
    }
  
