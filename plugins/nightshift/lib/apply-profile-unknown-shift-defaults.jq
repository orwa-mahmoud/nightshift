      .shiftDefaults | keys[] as $k
      | select((["verificationProfile","hours","toolingPolicy","execution"] | index($k)) == null)
      | $k
    
