    /<!--/ { comment = 1 }
    /-->/ { comment = 0; next }
    comment { next }
    /^###[[:space:]]+/ {
      title = $0
      sub(/^###[[:space:]]+/, "", title)
      sub(/[[:space:]]*$/, "", title)
      tline = NR
      building = 0
      next
    }
    /^Status:[[:space:]]*building[[:space:]]*$/ {
      building = 1
      print "T" tab tline tab title
      next
    }
    building && /^Current phase:[[:space:]]*/ {
      value = $0
      sub(/^Current phase:[[:space:]]*/, "", value)
      print "P" tab NR tab value
      next
    }
    building && /^Next:[[:space:]]*/ {
      value = $0
      sub(/^Next:[[:space:]]*/, "", value)
      print "N" tab NR tab value
      next
    }
  
