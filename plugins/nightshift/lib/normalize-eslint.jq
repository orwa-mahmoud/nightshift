def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
# eslint writes severity as a number, and a few formatters write the same number
# as a string. Both mean the same level, so both read as that number.
def sevnum: if type == "number" then . elif type == "string" then (try tonumber catch -1) else -1 end;
def sev: sevnum | if . == 2 then "error" elif . == 1 then "warning" else "note" end;
if type != "array" then "error\tthe report is not a JSON array"
elif ([.[] | (type == "object" and has("messages") and ((.messages | type) == "array"))]
      | index(false)) != null then "error\tthe report is not eslint file results"
else
  ([.[] | .messages[]]) as $m
  | ([$m[] | select((.severity | sevnum) == 2)] | length) as $e
  | ([$m[] | select((.severity | sevnum) == 1)] | length) as $w
  | ([.[] | select((.messages | length) > 0) | .filePath | cl] | unique | length) as $f
  | ( ["headline\teslint: " + plu($e; "error") + ", " + plu($w; "warning")
        + " in " + plu($f; "file")]
    + ["count\terrors\t\($e)", "count\twarnings\t\($w)", "files\t\($f)"]
    + [ .[] as $file | $file.messages[]
        | "item\t" + (.severity | sev) + "\t" + ($file.filePath | cl) + "\t"
          + ((.line // 0) | tostring) + "\t" + (.ruleId | cl) + "\t" + (.message | cl) ]
    ) []
end
