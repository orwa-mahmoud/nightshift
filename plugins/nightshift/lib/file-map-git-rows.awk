    NR == FNR { add[$1] = $2; del[$1] = $3; next }
    { a = ($1 in add) ? add[$1] : "0"; d = ($1 in del) ? del[$1] : "0"; print $1 "\t" $2 "\t" $3 "\t" a "\t" d }
  
