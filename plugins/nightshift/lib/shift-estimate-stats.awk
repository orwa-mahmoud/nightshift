    { v[++n] = $1 }
    END {
      if (n == 0) { print 0; exit }
      if (n % 2) m = v[(n + 1) / 2]
      else m = int((v[n / 2] + v[n / 2 + 1]) / 2)
      print n, m, v[1], v[n]
    }
