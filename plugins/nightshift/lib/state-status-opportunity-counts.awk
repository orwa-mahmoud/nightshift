    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^[[:space:]]*Status:[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]*Status:[[:space:]]*/, "", s)
      sub(/[[:space:]].*$/, "", s)
      gsub(/[^a-zA-Z]/, "", s)
      if (s != "") c[tolower(s)]++
    }
    END {
      printf "candidate=%d building=%d shipped=%d rejected=%d parked=%d",
        c["candidate"] + 0, c["building"] + 0, c["shipped"] + 0, c["rejected"] + 0, c["parked"] + 0
    }
  
