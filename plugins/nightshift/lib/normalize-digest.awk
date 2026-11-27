$1 == "headline" { h = $2; next }
$1 == "count" { nc++; cl[nc] = $2; cv[nc] = $3 + 0; next }
END {
  for (i = 2; i <= nc; i++) {
    kl = cl[i]; kv = cv[i]; j = i - 1
    while (j >= 1 && cl[j] > kl) { cl[j + 1] = cl[j]; cv[j + 1] = cv[j]; j-- }
    cl[j + 1] = kl; cv[j + 1] = kv
  }
  printf "normalize-output\t1\t%s\t%s\n", FORMAT, h
  for (i = 1; i <= nc; i++) printf "%s\t%d\n", cl[i], cv[i]
}
