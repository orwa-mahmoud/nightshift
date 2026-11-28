  { sub(/\r$/, "") }
  # Where the items are: under `## Items`, else below the first rule, else everywhere.
  FNR == 1 && !scanned {
    while ((getline l < FILENAME) > 0) {
      sub(/\r$/, "", l)
      if (l ~ /^##[[:space:]]*Items[[:space:]]*$/) { mode = "items"; break }
      if (l ~ /^--- *$/ && mode == "") mode = "rule"
    }
    close(FILENAME)
    if (mode == "") mode = "all"
    scanned = 1
    on = (mode == "all")
  }
  !on {
    if (mode == "items" && $0 ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1
    if (mode == "rule" && $0 ~ /^--- *$/) on = 1
    next
  }
  mode == "items" && /^## / { finish(); on = 0; next }

  # A Verify line is checkable when it names a command, a path or file, a number, quoted text, a URL
  # or a WHEN/THEN scenario. The hint is a question: it refuses nothing.
  function is_checkable(s) {
    return s ~ /`[^`]+`|[0-9]|[A-Za-z0-9_-]\/[A-Za-z0-9_.-]|\.[A-Za-z][A-Za-z]*|"[^"]+"|\047[^\047]+\047|https?:\/\/|WHEN .*THEN /
  }

  function finish() {
    if (!open) return
    if (!verify) print "find\tno Verify: line"
    else if (!checkable) print "find\tVerify: names no command, path, number or scenario; is it checkable?"
    if (!commit) print "find\tno Commit: line"
    if (evidence && !evidencetext) print "find\tEvidence: names nothing"
    if (budget != "") print "budget\t" budgettext
    for (i = 1; i <= nested; i++) print "find\tline " nestedat[i] ": a nested checkbox; only the item line may be a box"
    open = 0
  }

  # Fenced code and HTML comments hold no items, but a box written in them is still counted.
  fence || /^[[:space:]]*```/ {
    if (!fence && /^```/) finish()
    if (/^[[:space:]]*```/) fence = !fence
    if (/^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    next
  }
  comment {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    if ($0 ~ /-->/) comment = 0
    next
  }
  # A comment that opens here and runs on: nothing in it is an item. One that closes on the same
  # line, such as an item id, leaves the line as it was.
  {
    line = $0
    gsub(/<!--.*-->/, "", line)
  }
  line ~ /<!--/ {
    if ($0 !~ /^[[:space:]]/) finish()
    comment = 1
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    next
  }

  /^- \[[ xX-]\]/ {
    finish()
    label = $0
    sub(/^- \[.\][[:space:]]*/, "", label)
    sub(/[[:space:]]*<!--.*-->[[:space:]]*$/, "", label)
    print "item\t" label
    open = 1; verify = 0; checkable = 0; commit = 0; budget = ""; budgettext = ""; nested = 0; inverify = 0
    evidence = 0; evidencetext = 0; inevidence = 0
    next
  }

  /^[[:space:]]*$/ { inverify = 0; inevidence = 0; next }

  open && /^[[:space:]]+/ {
    indent = match($0, /[^[:space:]]/) - 1
    if (inverify && indent > verifyindent) { if (is_checkable($0)) checkable = 1; next }
    if (inevidence && indent > evidenceindent) { evidencetext = 1; next }
    inverify = 0; inevidence = 0
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[.\]/) { nestedat[++nested] = FNR; next }
    if ($0 ~ /^[[:space:]]*- Verify:/) {
      verify = 1; inverify = 1; verifyindent = indent
      if (is_checkable(substr($0, index($0, "Verify:") + 7))) checkable = 1
      next
    }
    if ($0 ~ /^[[:space:]]*- (Commit|Receipt):/) { commit = 1; next }
    if ($0 ~ /^[[:space:]]*- Evidence:/) {
      evidence = 1; inevidence = 1; evidenceindent = indent
      if ($0 !~ /^[[:space:]]*- Evidence:[[:space:]]*$/) evidencetext = 1
      next
    }
    if ($0 ~ /^[[:space:]]*- Budget:/) {
      budget = "yes"
      budgettext = $0
      sub(/^[[:space:]]*- Budget:[[:space:]]*/, "", budgettext)
      next
    }
    next
  }

  # Any other top-level line ends the item; a box written another way is one no item owns.
  {
    finish()
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
  }
  END { finish() }
