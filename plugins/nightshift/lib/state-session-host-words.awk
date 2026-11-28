    { sub(/\n$/, ""); if ($0 == "") next
      n = index($0, "/"); h = n ? substr($0, 1, n - 1) : $0; m = n ? substr($0, n + 1) : ""
      out = out (out == "" ? "" : " + ") h ((m != "" && m != "-") ? " · " m : "") }
    END { printf "%s", out }
