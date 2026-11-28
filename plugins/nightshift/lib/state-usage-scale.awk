BEGIN {
    if (n < 1000) { printf "%d", n; exit }
    split("1000 1000000 1000000000", unit, " ")
    split("k M B", suffix, " ")
    i = 1
    while (i < 3 && n >= unit[i + 1]) i++
    tenths = int((n * 10 + unit[i] / 2) / unit[i])
    if (tenths >= 10000 && i < 3) { i++; tenths = int((n * 10 + unit[i] / 2) / unit[i]) }
    printf "%d.%d%s", int(tenths / 10), tenths % 10, suffix[i]
  }
