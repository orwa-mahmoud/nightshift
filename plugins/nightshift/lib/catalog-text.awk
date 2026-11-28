  function ns_catalog_text(raw,    rest, line, i) {
    rest = raw
    sub(/\r$/, "", rest)
    line = ""
    while (length(rest) > 0) {
      if (ns_catalog_in_comment) {
        i = index(rest, "-->")
        if (i == 0) break
        rest = substr(rest, i + 3)
        ns_catalog_in_comment = 0
        continue
      }
      i = index(rest, "<!--")
      if (i == 0) { line = line rest; break }
      line = line substr(rest, 1, i - 1)
      rest = substr(rest, i + 4)
      ns_catalog_in_comment = 1
    }
    return line
  }
