    {
      $0 = ns_catalog_text($0)
      if (ns_catalog_in_comment) next
    }
    /^# / && !seen {
      seen = 1
      line = substr($0, 3)
      n = split(line, part, " \xe2\x80\x94 ")
      title = part[1]
      ending = (n >= 2) ? part[2] : ""
      summary = ""
      for (i = 3; i <= n; i++) {
        summary = summary (summary == "" ? "" : " - ") part[i]
      }
      next
    }
    seen && summary == "" && /^[^#[:space:]]/ {
      summary = $0
    }
    END {
      gsub(/\t/, " ", title)
      gsub(/\t/, " ", ending)
      gsub(/\t/, " ", summary)
      printf "%s\t%s\t%s\t%s\n", slug, ending, title, summary
    }
  
