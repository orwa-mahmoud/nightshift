    /^- \[[ xX-]\]/ && ns_item_label($0) == want { print ns_item_id($0); exit }
  
