    /^<!-- usage -->/ { usage = 1; next }
    /^<!-- \/usage -->/ { usage = 0; next }
    usage { next }
    /^<!-- nightshift:[a-z-]+ -->/ { generated = 1; next }
    /^<!-- \/nightshift:[a-z-]+ -->/ { generated = 0; next }
    generated { next }
    /^[[:space:]]*$/ { next }
    /^# / { next }
    /^\*\*Usage:\*\*/ { next }
    /^\*\*Duration:\*\*/ { next }
    /^\*\*Tokens:\*\* off$/ { next }
    /^\*\*Time:\*\* off$/ { next }
    /^  Source:/ { next }
    /^  Cache reads/ { next }
    /^  The input figure/ { next }
    /^  Cached input/ { next }
    /^  Overlap between/ { next }
    /^\| Tokens \|/ { next }
    /^\| Time \|/ { next }
    /^\| ---/ { next }
    /^\| input \|/ { next }
    /^\| cache / { next }
    /^\| output \|/ { next }
    /^\| reasoning \|/ { next }
    /^\| working \|/ { next }
    /^\| paused \|/ { next }
    /^\| wall \|/ { next }
    /^\| span \|/ { next }
    /^<!-- sessions -->/ { sessions = 1; next }
    /^<!-- \/sessions -->/ { sessions = 0; next }
    sessions { next }
    /^<!-- tokens / { next }
    /^<!-- item: / { next }
    /^Renamed from .* on [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.$/ { next }
    / · [0-9]+ segments?\./ { next }
    { print }
  
