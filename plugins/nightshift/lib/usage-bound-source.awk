    BEGIN { id = ENVIRON["NS_USAGE_BOUND_ID"] }
    $2 == host && ($1 == id || index($1, id "#") == 1 ||
      (host == "cursor" && index($1, id ":") == 1)) && $7 != "" {
      source = host "/" ($3 == "" ? "-" : $3)
    }
    END { printf "%s", source }
  
