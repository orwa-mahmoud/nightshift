    function emit(   l) { while ((getline l < blockfile) > 0) print l; close(blockfile); done = 1 }
    function out(l) { while (pend > 0) { print ""; pend-- } print l }
    function runtime(l) {
      return l ~ /^\*\*Usage:\*\*/ || l ~ /^\*\*Duration:\*\*/ || l ~ /^\*\*Tokens:\*\* off$/ ||
        l ~ /^\*\*Time:\*\* off$/ || l ~ /^  (Source:|Cache reads|The input figure|Cached input|Overlap between)/ ||
        l ~ /^\| (Tokens|Time) \|/ || l ~ /^\| ---/ ||
        l ~ /^\| (input|cache [a-z]+|output|reasoning|working|paused|wall|span) \|/ ||
        l ~ /^<!-- tokens / || l ~ / · [0-9]+ segments?\./
    }
    { line = $0; sub(/\r$/, "", line) }
    /^<!-- usage -->/ || /^<!-- sessions -->/ { skip = 1; next }
    skip && (/^<!-- \/usage -->/ || /^<!-- \/sessions -->/) { skip = 0; next }
    skip { next }
    !headed && line ~ /^# / { headed = 1; top = 1; print; print ""; emit(); pend = 0; next }
    top && (line ~ /^[[:space:]]*$/ || runtime(line)) { next }
    top && line ~ /^Renamed from .* on [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.$/ { print ""; print; next }
    top { top = 0; pend = 1 }
    /^[[:space:]]*$/ { pend++; next }
    { out($0) }
    END { if (!done) { print ""; emit() } }
  
