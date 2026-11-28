    $1 == "move" { moves = moves (moves == "" ? "" : ", ") $2 " -> " $3; n++ }
    $1 == "rename" { other = other "; " $2 " " $3 " -> " $4; n++ }
    $1 == "drop" || $1 == "retire" { settings++; n++ }
    $1 == "link" { links++; n++ }
    $1 == "ignore" { other = other "; " $2 " leaves " $3 " out"; n++ }
    $1 == "schema" { other = other "; " $2 " $schema -> " $4; n++ }
    $1 == "marker" { marker = "; state-version " $2 " -> " $3; n++ }
    END {
      if (n == 0) exit 1
      out = "move the state files into layout " version
      if (moves != "") out = out ": " moves
      out = out other
      if (settings) out = out "; " settings " retired setting" (settings == 1 ? "" : "s") " removed"
      if (links) out = out "; " links " link" (links == 1 ? "" : "s") " written again so they still resolve"
      out = out marker "; nothing is deleted or overwritten. Preview it with " cmd ", then run it again with --apply"
      print out
    }
