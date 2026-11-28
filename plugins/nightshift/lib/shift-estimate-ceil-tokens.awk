BEGIN {
    if (n < 1000000) { k = int((n + 999) / 1000); if (k < 1) k = 1; printf "%dk", k; exit }
    t = int((n + 99999) / 100000)
    if (t % 10) printf "%d.%dM", int(t / 10), t % 10
    else printf "%dM", t / 10
  }
