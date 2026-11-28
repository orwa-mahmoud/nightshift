    $1 == "state" { next }
    $1 == "refuse" { printf "  refuse    %s\n", $2; refused = 1; next }
    $1 == "move" { printf "  move      %s -> %s\n", $2, $3; n++; next }
    $1 == "leave" && $4 == "same" { printf "  leave     %s (the same content is already at %s)\n", $2, $3; next }
    $1 == "leave" { printf "  leave     %s/ (empty; %s/ is already there)\n", $2, $3; next }
    $1 == "conflict" && $4 != "" { printf "  conflict  %s %s\n", $2, $4; conflict = 1; next }
    $1 == "conflict" { printf "  conflict  %s and %s are both there and differ - keep one by hand\n", $2, $3; conflict = 1; next }
    $1 == "rename" { printf "  rename    %s: %s -> %s\n", $2, $3, $4; n++; next }
    $1 == "drop" { printf "  drop      %s: %s (the same value is already under %s)\n", $2, $3, $4; n++; next }
    $1 == "retire" { printf "  retire    %s: %s (no version reads it)\n", $2, $3; n++; next }
    $1 == "link" { printf "  link      %s: %s -> %s\n", $2, $3, $4; n++; next }
    $1 == "ignore" { printf "  ignore    %s: add %s\n", $2, $3; n++; next }
    $1 == "schema" { printf "  schema    %s: $schema -> %s\n", $2, $4; n++; next }
    $1 == "unknown" { printf "  unknown   %s (no Nightshift file has this name; left in place)\n", $2; next }
    $1 == "stray" { printf "  stray     %s (an earlier Setup copied a template here and nothing reads it; left in place, safe to delete)\n", $2; next }
    $1 == "note" { printf "  note      %s\n", $2; next }
    $1 == "marker" { printf "  marker    state-version %s -> %s\n", $2, $3; n++; next }
    END {
      if (refused || conflict) {
        print "Refused - nothing was changed."
      } else if (mode == "apply") {
        print "Applied. Nothing was deleted or overwritten."
      } else if (n == 0) {
        print "Every file is where the current layout keeps it; nothing to do."
      } else {
        print "Preview only - nothing was changed. Run it again with --apply to make these changes; nothing is deleted or overwritten."
      }
    }
