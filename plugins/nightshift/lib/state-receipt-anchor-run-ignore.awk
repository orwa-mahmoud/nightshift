      NR == FNR { if ($0 == new) has = 1; next }
      $0 == old { if (has) next; $0 = new; has = 1 }
      { print }
    
