    /[^\\]"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/ { last = tolower($0) }
    END {
      exit (last ~ /(rate|usage)[ _-]?limit/ ||
            last ~ /(^|[^0-9])(429|529)([^0-9]|$)/ ||
            last ~ /(^|[^a-z])api([^a-z]|$)/) ? 0 : 1
    }
