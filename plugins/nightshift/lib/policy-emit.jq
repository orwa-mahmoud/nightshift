# The JSON half of lib/policy.sh: turn one policy file into a flat fact stream.
#
# policy.sh owns every decision — validation, precedence, defaults, allowance matching. This
# program never decides anything; it reads. Three operations share one argument set so a single
# shell wrapper can bind it, selected by $op:
#
#   rules      .nightshift/rules.json. One line per guarded knob (present flag and value), per
#              elevation category (present flag and policy), and per owner-set category pattern.
#   shift      .nightshift/shift-policy.json. ty/k/j/n lines carry the JSON type, the keys, a
#              scalar's compact JSON, and an array's length at a dotted path; c, w and s lines
#              carry one approved command, write-surface entry, or selected-debt id each.
#   defaults   .nightshift/shift-defaults.json. One line per remembered choice.
#
# Every raw payload is control-scrubbed and every command is whitespace-normalized before it is
# emitted, so a fact line always holds exactly one fact and never a tab or a newline of its own.

def obj: if type == "object" then . else {} end;
def arr: if type == "array" then . else [] end;
def scrub: gsub("[\\x00-\\x1f\\x7f]"; " ");
def norm: gsub("[ \\t\\n\\x0b\\f\\r]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def jn($p; $k): if $p == "." then $k else $p + "." + $k end;
def ty($p): "ty\t" + $p + "\t" + type;
def ks($p): if type == "object" then (keys_unsorted[] | "k\t" + $p + "\t" + scrub) else empty end;
def sc($p; $names): . as $o | $names[] as $k | "j\t" + jn($p; $k) + "\t" + ($o | obj | .[$k] | tojson);
def cnt($p): "n\t" + $p + "\t" + (if type == "array" then length else -1 end | tostring);

def rules:
  obj as $R
  | ($R.elevation | obj) as $E
  | (["forbiddenCommands", "neverCommitPatterns", "expectedEmail", "protectedDirs",
      "stallMax", "watchMinutes"][] as $k
     | "r\t" + $k + "\t" + (if ($R | has($k)) then "1" else "0" end) + "\t" + ($R[$k] | tojson)),
    (["sudo", "containers", "global-packages", "daemons", "external-services"][] as $c
     | ($E[$c] | obj) as $x
     | ("e\t" + $c + "\t" + (if ($E | has($c)) then "1" else "0" end) + "\t"
        + (if ($x.policy | type) == "string" then ($x.policy | scrub) else "" end)),
       (if ($x.pattern | type) == "string" and ($x.pattern | length) > 0
        then "p\t" + $c + "\t" + ($x.pattern | scrub)
        else empty end));

def allowance($i; $a):
  ("allowances[" + ($i | tostring) + "]") as $ap
  | ($i | tostring) as $n
  | ($a | obj | .plan) as $plan
  | ($plan | obj | .commands) as $cs
  | ($plan | obj | .writeSurface) as $ws
  | ($a | ty($ap)),
    ($a | ks($ap)),
    ($a | obj | sc($ap; ["category", "scope", "provenance"])),
    ($plan | ty(jn($ap; "plan"))),
    ($plan | obj | ks(jn($ap; "plan"))),
    ($plan | obj | sc(jn($ap; "plan"); ["workTarget", "digest", "expiry"])),
    ($cs | ty(jn($ap; "plan.commands"))),
    ($cs | cnt(jn($ap; "plan.commands"))),
    ($cs | arr | to_entries[]
     | ("c\t" + $n + "\t" + (.key | tostring) + "\t"
        + (if (.value | type) == "string" then "s" else "x" end) + "\t"
        + (if (.value | type) == "string" then (.value | norm) else "" end)),
       ("q\t" + $n + "\t" + (.key | tostring) + "\t"
        + (if (.value | type) == "string" then (.value | norm | tojson) else "null" end))),
    ($ws | ty(jn($ap; "plan.writeSurface"))),
    ($ws | arr | to_entries[]
     | "w\t" + $n + "\t" + (.key | tostring) + "\t"
       + (if (.value | type) == "string" then "s" else "x" end));

# The owner preference blocks tonight's snapshot freezes. A block the snapshot does not carry
# emits its type and no fields, which is how a policy written before this feature is told apart
# from one whose owner left a block empty.
def PREF: {
  "shift":    ["execution", "hours", "toolingPolicy", "verificationProfile"],
  "recovery": ["launchScope"],
  "handoff":  ["detail", "enabled", "language", "sections", "templatePath", "view"],
  "archive":  ["automatic", "layout", "root", "templatePath"],
  "receipts": ["enabled", "progressMinutes", "progressMode",
               "progressTokens", "templatePath", "usage"]
};

def shift_policy:
  if type != "object" then "x\t.\tnotobject"
  else . as $P
  | ($P | ks(".")),
    ($P | sc("."; ["schemaVersion", "shiftId", "createdAt", "source", "deadlineEpoch",
                   "verificationLevel", "toolingPolicy", "launchScope", "launchProvenance",
                   "completionMode", "gatesDigest",
                   "contractDigest", "itemsDigest"])),
    (["shift", "recovery", "handoff", "archive", "receipts"][] as $b
     | ($P[$b] | ty($b)),
       (if ($P | has($b)) then ($P[$b] | obj | sc($b; PREF[$b])) else empty end)),
    ($P.budgets | ty("budgets")),
    ($P.budgets | obj | to_entries[] | "b\t" + (.key | scrub) + "\t" + (.value | tojson)),
    ($P.selectedDebt | ty("selectedDebt")),
    ($P.selectedDebt | cnt("selectedDebt")),
    ($P.selectedDebt | arr | to_entries[]
     | "s\t" + (.key | tostring) + "\t"
       + (if (.value | type) == "string" then "s" else "x" end) + "\t"
       + (.value | tojson)),
    ($P.allowances | ty("allowances")),
    ($P.allowances | cnt("allowances")),
    ($P.allowances | arr | to_entries[] | allowance(.key; .value))
  end;

def defaults:
  if type != "object" then "x\t.\tnotobject"
  else . as $D
  | ["schemaVersion", "verificationProfile", "hours", "toolingPolicy", "execution",
     "updatedAt"][] as $k
  | "d\t" + $k + "\t" + (if ($D | has($k)) then "1" else "0" end) + "\t" + ($D[$k] | tojson)
  end;

  if $op == "rules" then rules
elif $op == "shift" then shift_policy
else defaults
end
