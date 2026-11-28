    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^#{2,}[[:space:]]/ {
      if (found) exit
      title = $0
      sub(/^#+[[:space:]]*/, "", title)
      gsub(/\*\*/, "", title)
      building = 0
      next
    }
    /^[[:space:]]*Status:[[:space:]]*building/ {
      building = 1
      found = 1
      print "title\t" title
      next
    }
    building && /^[[:space:]]*(Phase|Next|Verify remaining):/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      key = line
      sub(/:.*$/, "", key)
      sub(/^[^:]*:[[:space:]]*/, "", line)
      print tolower(key) "\t" line
    }
  
