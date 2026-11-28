    { sub(/\r$/, "") }
    /^- / {
      n = split(substr($0, 3), f, / · /)
      action = f[1]
      if (index(actions, " " action " ") == 0) next
      name = "unknown"; rev = ""
      if (n >= 4 && f[2] !~ /^revision / && f[3] !~ /^revision /) name = f[2]
      for (i = 2; i <= n; i++) if (f[i] ~ /^revision /) rev = substr(f[i], 10)
      printf "%s\t%s\t%s\t%s\n", action, name, rev, $0
    }
