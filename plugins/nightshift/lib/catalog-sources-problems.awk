    function fail(msg) { print msg; bad = 1 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN {
      nkey = split("files min type", allowed, " ")
      ntype = split("image text json any", allowed_type, " ")
      fence = (substr(rule, 1, 6) == "fence:") ? substr(rule, 7) : ""
    }
    {
      line = ns_catalog_text($0)
      if (ns_catalog_in_comment) next
      if (rule == "shift" && !seen_h1 && line ~ /^# / && line !~ /^## /) {
        seen_h1 = 1
        n = split(substr(line, 3), part, " \xe2\x80\x94 ")
        if (n < 2 || (part[2] != "finite" && part[2] != "open-ended")) fail("H1 must name the ending: finite or open-ended")
        next
      }
      if (line ~ /^```/ && !in_check) {
        if (fence != "" && line ~ ("^```" fence "[[:space:]]*$")) {
          in_check = 1
          seen_fence = 1
          delete seenk
          next
        }
        in_block = !in_block
        if (in_block && line ~ /^```text[[:space:]]*$/) { in_text = 1; box = 0; verify = 0 }
        if (!in_block) {
          if (in_text && box) { any_box = 1; if (verify) item_ok = 1 }
          in_text = 0
        }
        next
      }
      if (in_check && line ~ /^```[[:space:]]*$/) {
        for (k = 1; k <= nkey; k++) if (!(allowed[k] in seenk)) fail("missing key")
        in_check = 0
        next
      }
      if (in_check) {
        if (line !~ /^[a-z]+:[[:space:]]*[^[:space:]].*$/) { fail("unknown key"); next }
        key = line
        sub(/:.*/, "", key)
        ok = 0
        for (k = 1; k <= nkey; k++) if (allowed[k] == key) ok = 1
        if (!ok) { fail("unknown key"); next }
        if (key in seenk) { fail("duplicate key"); next }
        val = line
        sub(/^[^:]+:[[:space:]]*/, "", val)
        if (key == "min" && val !~ /^[1-9][0-9]*$/) fail("invalid min")
        if (key == "type") {
          ok = 0
          for (k = 1; k <= ntype; k++) if (allowed_type[k] == val) ok = 1
          if (!ok) fail("invalid type")
        }
        seenk[key] = val
        next
      }
      if (in_text) {
        if (line ~ /^- \[ \] \*\*/) box = 1
        if (index(line, "Verify:")) verify = 1
        next
      }
      if (in_block) next
      if (rule == "match" && line ~ /^Match:[[:space:]]*/) {
        val = trim(substr(line, 7))
        if (val != "stack" && val != "plugin" && val != "fallback") fail("invalid match")
        if (match_seen) fail("duplicate match")
        match_seen = 1
      }
    }
    END {
      if (rule == "shift" && !seen_h1) fail("H1 must name the ending: finite or open-ended")
      if (rule == "shift" && !any_box) fail("no pasteable item: a text block with a box")
      if (rule == "shift" && any_box && !item_ok) fail("the item has no Verify line")
      if (rule == "match" && !match_seen) fail("missing match")
      if (in_check || in_block) fail("unclosed fence")
      if (notes != "" && fence != "" && !seen_fence) print "note: no " fence " block, so check: block holds only the files an item names"
      exit bad ? 1 : 0
    }
  
