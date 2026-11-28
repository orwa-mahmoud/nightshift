def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
# A zero denominator is not full coverage; it is no measurement, and -1 is how
# every reader of these three tells one from the other.
def bp($c; $t): if $t <= 0 then -1 else (($c * 20000 + $t) / (2 * $t) | floor) end;
def pl($c; $t): bp($c; $t) as $b
  | if $b < 0 then "unmeasured"
    else "\($b / 100 | floor).\((100 + ($b % 100)) | tostring | .[1:])%" end;
def band($c; $t): bp($c; $t) as $b
  | if $b < 0 then "info" elif $b < 5000 then "error" elif $b < 8000 then "warning"
    else "note" end;
def num($o; $k): (($o[$k] // 0) | if type == "number" then floor else 0 end);
if type != "object" then "error\tthe report is not a JSON object"
elif (has("total") | not) or ((.total | type) != "object")
     or ((.total | has("lines")) | not) then "error\tthe report has no total.lines block"
else
  . as $r
  | (.total) as $t
  | ([$r | keys[] | select(. != "total")]) as $files
  | ( ["headline\tcoverage: lines " + pl(num($t.lines; "covered"); num($t.lines; "total"))
        + ", statements " + pl(num($t.statements; "covered"); num($t.statements; "total"))
        + ", functions " + pl(num($t.functions; "covered"); num($t.functions; "total"))
        + ", branches " + pl(num($t.branches; "covered"); num($t.branches; "total"))
        + " across " + plu(($files | length); "file")]
    + [ "count\tbranchesCovered\t\(num($t.branches; "covered"))",
        "count\tbranchesTotal\t\(num($t.branches; "total"))",
        "count\tfunctionsCovered\t\(num($t.functions; "covered"))",
        "count\tfunctionsTotal\t\(num($t.functions; "total"))",
        "count\tlinesCovered\t\(num($t.lines; "covered"))",
        "count\tlinesTotal\t\(num($t.lines; "total"))",
        "count\tstatementsCovered\t\(num($t.statements; "covered"))",
        "count\tstatementsTotal\t\(num($t.statements; "total"))",
        "files\t\($files | length)" ]
    + [ $files[] as $k
        | ($r[$k].lines // {}) as $l
        | (num($l; "covered")) as $c | (num($l; "total")) as $n
        | "item\t" + band($c; $n) + "\t" + ($k | cl) + "\t0\tlines\t"
          + "\($c)/\($n) lines covered (" + pl($c; $n) + ")" ]
    ) []
end
