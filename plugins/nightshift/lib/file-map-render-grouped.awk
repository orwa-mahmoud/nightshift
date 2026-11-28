      function counts() { return ($5 == "-") ? "binary" : "+" $5 " -" $6 }
      {
        if (NR == 1 || $1 != dir) { dir = $1; print (dir == "" ? "./" : dir "/") }
        if (kind == "git") {
          line = "  " $3 " " $2 "  " counts()
          if ($4 != "") line = line "  (from " $4 ")"
        } else {
          line = "  " $2
        }
        print line
      }
