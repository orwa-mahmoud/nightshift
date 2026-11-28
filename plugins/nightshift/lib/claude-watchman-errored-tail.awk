    /[^\\]"type"[[:space:]]*:[[:space:]]*"(user|assistant)"/ {
      wedge = /[^\\]"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/
    }
    END { exit wedge ? 0 : 1 }
