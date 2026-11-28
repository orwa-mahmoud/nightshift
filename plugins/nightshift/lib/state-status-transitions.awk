    {
      line = $0
      # Both writers lead with a dash, a timestamp and a separator before the message. Everything up
      # to the first letter is that preamble, in any locale and with any separator byte.
      sub(/^[^A-Za-z]*/, "", line)
      # A local stamp carries its UTC offset in words; it is part of the preamble too.
      if (sub(/^UTC[+-][0-9][0-9]:[0-9][0-9]\)/, "", line)) sub(/^[^A-Za-z]*/, "", line)
    }
    # A transition is a line whose SUBJECT is the shift changing hands. Matching the words anywhere
    # would catch an item summary that merely mentions one.
    tolower(line) ~ /^(watchman|the watchman|shift started|shift ended|the session ended|revived|host change)/ {
      if (length(line) > 120) line = substr(line, 1, 117) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  
