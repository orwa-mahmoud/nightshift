def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
def lvl: (. // "warning") | if . == "error" or . == "warning" or . == "note" then . else "note" end;
def uri: (.locations // [])
  | if length == 0 then "-"
    else (.[0].physicalLocation.artifactLocation.uri // "-") end;
def ln: (.locations // [])
  | if length == 0 then 0 else (.[0].physicalLocation.region.startLine // 0) end;
if type != "object" then "error\tthe report is not a JSON object"
elif (has("runs") | not) or ((.runs | type) != "array")
  then "error\tthe report has no runs array"
elif (has("version") and ((.version | tostring) | startswith("2.1") | not))
  then "error\tthe report is not SARIF 2.1"
else
  ([.runs[] | .results // [] | .[]]) as $res
  | ([$res[] | select((.level | lvl) == "error")] | length) as $e
  | ([$res[] | select((.level | lvl) == "warning")] | length) as $w
  | ([$res[] | select((.level | lvl) == "note")] | length) as $n
  | ([$res[] | uri | cl] | unique | length) as $f
  | ( ["headline\tsarif: " + plu($e; "error") + ", " + plu($w; "warning") + ", "
        + plu($n; "note") + " in " + plu($f; "file")]
    + ["count\terrors\t\($e)", "count\tnotes\t\($n)", "count\twarnings\t\($w)",
       "files\t\($f)"]
    + [ $res[]
        | "item\t" + (.level | lvl) + "\t" + (uri | cl) + "\t" + (ln | tostring) + "\t"
          + (.ruleId | cl) + "\t" + ((.message.text // .message.markdown) | cl) ]
    ) []
end
