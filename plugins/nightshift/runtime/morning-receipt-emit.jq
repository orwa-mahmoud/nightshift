# The JSON half of morning-receipt.sh: lift printable values out of the documents the receipt
# renders, and nothing else.
#
# morning-receipt.sh owns every decision — which sections a view carries, what each line says,
# what an absent value renders as, what order rows come in. This program never decides anything;
# it reads. Four operations share one argument set so a single shell wrapper can bind it,
# selected by $op:
#
#   recs      the ledger as raw text. One group per non-empty line: kind r or u, the $fields
#             cells, and the line's index, $FS between fields and $RS after the group. A line
#             that is not a JSON object comes back as kind u with empty cells, so a record's
#             index still lines up with its details.
#   details   the ledger as raw text. <index> $FS <key> $FS <value> $RS for every key of a
#             record's details object, keys in byte order. A domain's extra fields live there,
#             so they travel as opaque pairs the shell prints without knowing their names.
#   policy    one accepted shift-policy document. The shell classifies the file first
#             (absent / malformed / accepted) and only asks for fields when the document
#             validates. One h group — shiftId, createdAt, source,
#             verificationLevel, toolingPolicy, completionMode, the selectedDebt ids joined by
#             ", " — then one a group per allowance in document order: category, scope,
#             provenance.
#   compare   one comparison document. <ids> $FS <sources> $FS <status> $FS <locator> $RS per
#             row, ids and sources joined by ", ", taking the first key present of each alias
#             set and skipping a row that is not an object.
#
# Every payload is control-scrubbed before it enters the stream, so a group carries exactly the
# cells it declares and never a separator of its own.

def scrub: gsub("[\\x00-\\x1f\\x7f]"; " ");

def canonjson:
  if type == "object"
  then "{" + ([to_entries | sort_by(.key) | .[] | (.key | tojson) + ":" + (.value | canonjson)]
              | join(",")) + "}"
  elif type == "array" then "[" + ([.[] | canonjson] | join(",")) + "]"
  else tojson
  end;

def cell:
  (if . == null then ""
   elif type == "string" then .
   elif type == "boolean" or type == "number" then tojson
   else canonjson
   end)
  | scrub;

def names($s): $s | split("\n") | map(select(length > 0));

def field($k): if type == "object" then .[$k] else null end;

def firstof($keys): . as $r
  | [$keys[] | . as $k | $r | field($k) | select(. != null)]
  | (.[0] // null);

def listcell: if type == "array" then ([.[] | cell] | join(", ")) else cell end;

def payload: split("\n") | map(select(length > 0));

def parse: try fromjson catch null;

def recs($fields; $FS; $RS):
  payload
  | to_entries[]
  | .key as $i
  | (.value | parse) as $r
  | if ($r | type) == "object"
    then "r" + $FS + ([$fields[] | . as $k | $r | field($k) | cell] | map(. + $FS) | join(""))
      + ($i | tostring) + $RS
    else "u" + $FS + ([$fields[] | ""] | map(. + $FS) | join("")) + ($i | tostring) + $RS
    end;

def details($FS; $RS):
  payload
  | to_entries[]
  | .key as $i
  | (.value | parse | field("details")) as $d
  | if ($d | type) == "object"
    then ($d | to_entries | sort_by(.key) | .[]
      | ($i | tostring) + $FS + (.key | scrub) + $FS + (.value | cell) + $RS)
    else empty
    end;

def policy($FS; $RS):
  (if type == "object" then . else {} end) as $P
  | ("h" + $FS
      + ([["shiftId", "createdAt", "source", "verificationLevel", "toolingPolicy",
           "completionMode"][] | . as $k | $P | field($k) | cell]
         | map(. + $FS) | join(""))
      + ([$P | field("selectedDebt") | if type == "array" then .[] else empty end | cell]
         | join(", "))
      + $RS),
    ($P | field("allowances")
      | if type == "array" then .[] else empty end
      | select(type == "object")
      | "a" + $FS + (field("category") | cell) + $FS + (field("scope") | cell)
        + $FS + (field("provenance") | cell) + $RS);

def compare($FS; $RS):
  . as $doc
  | (if ($doc | type) == "array" then $doc
     elif ($doc | type) == "object"
     then (($doc | firstof(["rows", "findings", "comparison", "entries"])) as $r
       | if ($r | type) == "array" then $r else [] end)
     else []
     end)
  | .[]
  | select(type == "object")
  | (firstof(["id", "finding", "recordId"]) | cell) as $id
  | (firstof(["class", "classification", "state"]) | cell) as $class
  | (firstof(["digest"]) | cell) as $digest
  | (firstof(["sources", "sourceClass", "source"]) | listcell) as $sources
  | (firstof(["locator", "at"]) | cell) as $locator
  | $id + $FS + $class + $FS + $digest + $FS + $sources + $FS + $locator + $RS;

  if $op == "recs" then recs(names($fields); $FS; $RS)
elif $op == "details" then details($FS; $RS)
elif $op == "policy" then policy($FS; $RS)
else compare($FS; $RS)
end
