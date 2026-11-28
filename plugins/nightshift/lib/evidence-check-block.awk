    {
      $0 = ns_catalog_text($0)
      if (ns_catalog_in_comment) next
    }
    /^```evidence-check[[:space:]]*$/ { on = 1; next }
    on && /^```[[:space:]]*$/ { exit }
    on && /^files:[[:space:]]*/ { files = $0; sub(/^[^:]+:[[:space:]]*/, "", files) }
    on && /^min:[[:space:]]*/ { min = $0; sub(/^[^:]+:[[:space:]]*/, "", min) }
    on && /^type:[[:space:]]*/ { type = $0; sub(/^[^:]+:[[:space:]]*/, "", type) }
    END {
      if (files != "" || min != "" || type != "") print files "\t" min "\t" type
    }
  
