    function starts_item(line) { return line ~ /^- \[[ xX-]\]/ }
    # A top-level line is anything not indented: the next item, a heading, a note. Either way this
    # item has ended.
    function top_level(line) { return line !~ /^[[:space:]]/ && line != "" }
    function number(label) {
      if (match(label, /^[0-9]+/)) return substr(label, RSTART, RLENGTH)
      if (match(label, /^[A-Za-z]+[0-9]+/)) return substr(label, RSTART, RLENGTH)
      return ""
    }
    {
      if (!on && starts_item($0)) {
        if (want == "") {
          if ($0 !~ /^- \[ \]/) next
          on = 1
          print
          next
        }
        label = ns_item_label($0)
        if (label != want && ns_item_id($0) != want && number(label) != want) next
        on = 1
        print
        next
      }
      if (on) {
        if (top_level($0)) exit
        print
      }
    }
  
