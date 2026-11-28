def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
def sev: (. // "info")
  | if . == "critical" or . == "high" or . == "moderate" or . == "low" then . else "info" end;
def title: (.via // [])
  | if length == 0 then "-"
    else (.[0] | if type == "object" then (.title // "-") else tostring end) end;
def fixed: if (.fixAvailable // false) == false then "none" else "available" end;
if type != "object" then "error\tthe report is not a JSON object"
elif (has("advisories") and ((has("auditReportVersion")) | not))
  then "error\tthe report predates npm audit version 7"
elif (has("auditReportVersion") | not) or ((.vulnerabilities | type) != "object")
  then "error\tthe report has no npm audit vulnerabilities object"
else
  . as $r
  | ([.vulnerabilities | keys[]]) as $names
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "critical")] | length) as $c
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "high")] | length) as $h
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "moderate")] | length) as $m
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "low")] | length) as $l
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "info")] | length) as $i
  | ($names | length) as $t
  | ( ["headline\tnpm-audit: " + plu($t; "vulnerable package") + ": \($c) critical, \($h) high, "
        + "\($m) moderate, \($l) low, \($i) info"]
    + ["count\tcritical\t\($c)", "count\thigh\t\($h)", "count\tinfo\t\($i)",
       "count\tlow\t\($l)", "count\tmoderate\t\($m)", "count\ttotal\t\($t)",
       "files\t\($t)"]
    + [ $names[] as $k | $r.vulnerabilities[$k]
        | "item\t" + (.severity | sev) + "\t" + ($k | cl) + "\t0\t"
          + ((.range // "-") | cl) + "\t" + (title | cl) + "; fix: " + fixed ]
    ) []
end
