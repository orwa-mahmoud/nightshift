    FNR == NR {
      if ($1 == "contract") before_contract = $2
      else if ($1 == "item") {
        before[$2] = $4; before_label[$2] = $3; order[++n] = $2
        if (!($3 in by_label)) by_label[$3] = $2
      }
      next
    }
    $1 == "contract" { if (before_contract != "" && $2 != before_contract) print "contract"; next }
    $1 == "item" {
      key = $2
      if (!(key in before) && ($3 in by_label) && !(by_label[$3] in seen)) key = by_label[$3]
      if (!(key in before)) { print "added\t" $3; next }
      seen[key] = 1
      if (before[key] != $4) print "reworded\t" $3
    }
    END { for (i = 1; i <= n; i++) if (!(order[i] in seen)) print "removed\t" before_label[order[i]] }
  
