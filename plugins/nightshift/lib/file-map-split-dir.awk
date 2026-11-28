NF {
        p = $1; d = ""; b = p
        i = match(p, /\/[^\/]*$/)
        if (i) { d = substr(p, 1, i - 1); b = substr(p, i + 1) }
        print d "\t" b "\t" $2 "\t" $3 "\t" $4 "\t" $5
      }
