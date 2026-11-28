    {
      $0 = ns_catalog_text($0)
      if (ns_catalog_in_comment) next
    }
    /^# / && !/^## / && !seen {
      seen = 1
      line = substr($0, 3)
      n = split(line, part, " \xe2\x80\x94 ")
      title = part[1]
      description = ""
      for (i = 2; i <= n; i++) {
        description = description (i == 2 ? "" : " \xe2\x80\x94 ") part[i]
      }
      gsub(/\t/, " ", title)
      gsub(/\t/, " ", description)
      printf "%s\t%s", title, description
      exit
    }
  
