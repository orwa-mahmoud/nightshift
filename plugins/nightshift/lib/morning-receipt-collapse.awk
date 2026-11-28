    function flush() {
      if (n == 0) return
      if (n == 1) { print first_line; n = 0; return }
      last = last_stamp
      if (substr(last_stamp, 1, 10) == substr(first_stamp, 1, 10)) last = substr(last_stamp, 12)
      print first_stamp " to " last sep msg " (" n " times)"
      n = 0
    }
    {
      i = index($0, sep)
      if (i > 0) { stamp = substr($0, 1, i - 1); m = substr($0, i + length(sep)) } else { stamp = ""; m = $0 }
      if (n > 0 && stamp != "" && first_stamp != "" && m == msg) { n++; last_stamp = stamp; next }
      flush()
      n = 1; msg = m; first_stamp = stamp; last_stamp = stamp; first_line = $0
    }
    END { flush() }
