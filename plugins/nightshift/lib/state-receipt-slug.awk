    {
      s = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        o = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
        if (o) c = substr("abcdefghijklmnopqrstuvwxyz", o, 1)
        if (c ~ /[a-z0-9]/) s = s c
        else s = s "-"
      }
      gsub(/-+/, "-", s)
      gsub(/^-|-$/, "", s)
      if (length(s) > 60) {
        s = substr(s, 1, 60)
        gsub(/-$/, "", s)
      }
      print s
    }
  
