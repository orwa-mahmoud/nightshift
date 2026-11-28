    /^- \[[ xX-]\]/ {
      label = ns_item_label($0)
      if (label != "") print (($0 ~ /^- \[ \]/) ? "open" : ($0 ~ /^- \[-\]/) ? "stopped" : "ticked") "\t" label "\t" ns_item_id($0)
    }
  
