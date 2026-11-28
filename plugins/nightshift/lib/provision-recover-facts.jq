def p: tojson;
if type != "object" then "k\tother"
else
  "k\tobject",
  ("s\t" + (.stage | p)),
  ("c\t" + (.capabilityId | p)),
  ("w\t" + (.workTarget | p)),
  ("f\t" + (.failed | p)),
  ("r\t" + (.recipePath | p)),
  ("g\t" + (.touched | type)),
  (if (.touched | type) == "array" then (.touched[] | "u\t" + p) else empty end),
  ("a\t" + (.allowedFiles | type)),
  (if (.allowedFiles | type) == "array" then (.allowedFiles[] | "p\t" + p) else empty end),
  ("b\t" + (.baseline | type)),
  (if (.baseline | type) == "object"
   then (.baseline | to_entries | sort_by(.key)[]
         | "e\t" + (.key | p) + "\t" + (.value | type) + "\t"
           + (if (.value | type) == "object" then (.value.existed | p) else "null" end) + "\t"
           + (if (.value | type) == "object" then (.value.digest | p) else "null" end) + "\t"
           + (if (.value | type) == "object" then (.value.blob | p) else "null" end) + "\t"
           + (if (.value | type) == "object"
              then (if (.value.content | type) == "string" and (.value.content | length) > 0
                    then "1" else "0" end)
              else "0" end))
   else empty end)
end
