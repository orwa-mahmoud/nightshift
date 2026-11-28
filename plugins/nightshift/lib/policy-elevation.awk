          BEGIN { old = ENVIRON["NS_ELEV_OLD"]; new = ENVIRON["NS_ELEV_NEW"] }
          {
            rest = $0
            while ((i = index(rest, old)) > 0) {
              printf "%s%s", substr(rest, 1, i - 1), new
              rest = substr(rest, i + length(old))
            }
            print rest
          }
