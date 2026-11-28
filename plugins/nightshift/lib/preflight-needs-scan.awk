    function emit(text,   t) {
      t = text
      gsub(/[\001-\010\013\014\016-\037\177]/, " ", t)
      gsub(/\t/, " ", t)
      gsub(/[*`]/, " ", t)
      printf "L\t%s\t%d\t%s\n", src, idx, t
    }
    /^[[:space:]]*-[[:space:]]*\[[[:space:]xX-]\]/ {
      n++
      idx = n
      open = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/)
      if (open) {
        title = $0
        sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]xX-]\][[:space:]]*/, "", title)
        gsub(/[*`]/, "", title)
        gsub(/[\001-\037\177]/, " ", title)
        gsub(/[[:space:]]+/, " ", title)
        sub(/^ /, "", title)
        sub(/ $/, "", title)
        printf "T\t%s\t%d\t%s\n", src, idx, title
        emit($0)
      }
      next
    }
    /^##[[:space:]]/ { open = 0; next }
    open { emit($0) }
  
