    /^#/ || NF < 3 { next }
    $1 == kind && $2 == topic { print $3 }
  
