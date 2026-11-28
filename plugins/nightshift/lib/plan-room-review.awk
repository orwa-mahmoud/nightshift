      /^- \[ \]/ { kind = "open" }
      /^- \[-\]/ { kind = "stopped" }
      /^- \[( |-)\]/ {
        line = $0
        sub(/^- \[.\][[:space:]]*/, "", line)
        sub(/[[:space:]]*<!--.*-->[[:space:]]*$/, "", line)
        print kind " " line
      }
