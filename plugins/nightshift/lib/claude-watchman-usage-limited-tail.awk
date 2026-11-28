    /[^\\]"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/ { last = tolower($0) }
    END { exit (last ~ /usage[ _-]?limit/) ? 0 : 1 }
