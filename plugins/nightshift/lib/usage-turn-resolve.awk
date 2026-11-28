    {
      if ($4 == "" && $2 < nr) $4 = entry
      else {
        n = split($4, c, ";"); out = ""
        for (i = 1; i <= n; i++) out = out (out == "" ? "" : ";") (c[i] == open ? entry : c[i])
        $4 = out
      }
      print
    }
