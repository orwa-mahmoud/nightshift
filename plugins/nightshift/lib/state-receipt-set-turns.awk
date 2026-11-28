    {
      n = split($0, f, " "); hit = 0
      for (i = 8; i <= n; i++) if (f[i] == cp) hit = 1
      if (!hit) { print; next }
      out = f[1]
      for (i = 2; i <= n; i++) if (i < 8 || f[i] !~ /^(turn|with)=/) out = out " " f[i]
      m = split(turns, t, " ")
      for (i = 1; i <= m; i++) out = out " turn=" t[i]
      print out
    }
