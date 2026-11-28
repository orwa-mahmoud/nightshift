      BEGIN { was = ENVIRON["NS_WAS"]; now = ENVIRON["NS_NOW"]; day = ENVIRON["NS_DAY"] }
      { line = $0; sub(/\r$/, "", line) }
      !headed && line ~ /^# / {
        headed = 1
        print (line == "# " was) ? "# " now : $0
        print ""
        print "Renamed from " was " on " day "."
        next
      }
      line ~ /^<!-- item: .* -->[[:space:]]*$/ { print "<!-- item: " now " -->"; next }
      { print }
    
