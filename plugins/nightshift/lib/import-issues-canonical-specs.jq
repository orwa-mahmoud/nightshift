    if (.labels | type) == "array" then
      [ .labels[] | .name // empty ] | map(select(length > 0)) | join(", ")
    else
      ""
    end
  
