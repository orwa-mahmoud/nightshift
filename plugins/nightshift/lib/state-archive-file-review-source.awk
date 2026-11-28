        { l = $0; sub(/\r$/, "", l) }
        l ~ /^--- *$/ { printf "%s%s", head, blanks; print; done = 1; exit }
        l ~ /^- / { exit }
        l == "" { blanks = blanks $0 "\n"; next }
        { head = head blanks $0 "\n"; blanks = "" }
        END { if (!done) printf "%s", head }
      
