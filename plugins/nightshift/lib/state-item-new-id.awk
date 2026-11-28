      NF >= 4 {
        a = "abcdefghijklmnopqrstuvwxyz"; b = a "0123456789"
        printf "%s%s%s%s", substr(a, $1 % 26 + 1, 1), substr(b, $2 % 36 + 1, 1),
          substr(b, $3 % 36 + 1, 1), substr(b, $4 % 36 + 1, 1)
      }
