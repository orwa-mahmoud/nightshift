    BEGIN {
      FS = "\t"
      nr = split(ENVIRON["NS_OVERLAY_RUN"], run, "\n")
      for (i = 1; i <= nr; i++) {
        if (run[i] == "") continue
        print run[i]
        split(run[i], f, "\t")
        if (f[4] == "a") arr[f[1] SUBSEP f[2]] = 1
        else have[f[1] SUBSEP f[2] SUBSEP f[3]] = 1
      }
      ns = split(ENVIRON["NS_OVERLAY_SHARED"], shared, "\n")
      for (i = 1; i <= ns; i++) {
        if (shared[i] == "") continue
        split(shared[i], f, "\t")
        if ((f[1] SUBSEP f[2]) in arr) continue
        if ((f[1] SUBSEP f[2] SUBSEP f[3]) in have) continue
        print shared[i]
      }
    }
