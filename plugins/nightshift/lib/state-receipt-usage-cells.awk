{ for (i = 2; i <= 6; i++) if ($i ~ /^[0-9]+$/) s[i] = 1 }
          END { for (i = 2; i <= 6; i++) printf "%s", (s[i] ? 1 : 0) }
