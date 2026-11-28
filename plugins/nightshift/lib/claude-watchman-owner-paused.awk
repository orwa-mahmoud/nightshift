    /[^\\]"type"[[:space:]]*:[[:space:]]*"(user|assistant)"/ {
      esc = /Request interrupted by user/
    }
    END { exit esc ? 0 : 1 }
