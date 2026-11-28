    {
      s = $0
      while (match(s, /`[^`]*`/)) {
        name = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        if (name == "" || name ~ /\// || name ~ /\\/ || name == "." || name == "..") continue
        print name
      }
    }
  
