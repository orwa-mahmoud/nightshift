    {
      if (match($0, /^[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
      if (match($0, /^[A-Za-z]+[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
    }
  
