    BEGIN {
      while ((getline row < reopened) > 0) {
        if (split(row, f, "\t") == 2 && f[1] ~ /^[0-9]+$/) ignored[f[2]] = f[1] + 0
      }
      close(reopened)
      while ((getline row < marks) > 0) {
        rows++
        n = split(row, f, "\t")
        # The first mark is the shift arming, not an item, and only a tick closes an item: a switch
        # or a pause charges a span to an item that is still open.
        if (rows == 1 && f[2] == "arm") continue
        if (n >= 4 && f[4] != "" && f[4] != "tick") continue
        charged[f[2]]++
      }
      close(marks)
    }
    /^\+/ { open[substr($0, 2)] = 1; next }
    { label = substr($0, 2); labels[++nlabels] = label; closed[label]++ }
    END {
      if (observed != "") {
        for (label in open) {
          count = charged[label] - closed[label]
          if (count <= ignored[label]) continue
          ignored[label] = count
          print count "\t" label >> observed
        }
      }
      for (i = 1; i <= nlabels; i++) {
        label = labels[i]
        if (charged[label] > ignored[label]) charged[label]--
        else print label
      }
    }
  
