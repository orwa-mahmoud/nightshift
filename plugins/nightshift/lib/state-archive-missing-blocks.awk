    BEGIN {
      have = "\n"
      while ((getline l <filed) > 0) { sub(/\r$/, "", l); have = have l "\n" }
      close(filed)
    }
    function flush(   b) {
      if (buf == "") return
      b = buf
      sub(/\n+$/, "", b)
      if (index(have, "\n" b "\n") == 0) printf "%s\n", b
      buf = ""
    }
    { l = $0; sub(/\r$/, "", l) }
    buf != "" && l ~ /^ *(- )?(\*\*)?(Default|Rollback):/ { buf = buf l "\n"; next }
    l ~ /^- / { flush(); buf = l "\n"; next }
    buf != "" { buf = buf l "\n"; next }
    END { flush() }
  
