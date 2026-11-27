($recipe[0]) as $r
| (if ($r.smoke | type) == "object"
   then (if (($r.smoke.command // "") | tostring) != "" then $r.smoke.command
         elif (($r.smoke.cmd // "") | tostring) != "" then $r.smoke.cmd
         else "" end)
   elif ($r.smoke | type) == "string" then $r.smoke
   else "" end) as $command
| {capability: $cap, command: $command, source: "recipe", verifiedAt: $now,
   configFiles: (if ($r.allowedFiles | type) == "array" then $r.allowedFiles else [] end),
   recipeVersion: $r.recipeVersion, setupCommit: $setup} as $item
| (if ($base | type) == "object" then $base else {items: []} end)
| .items = (((if (.items | type) == "array" then .items else [] end)
             | map(select((type == "object") and (.capability != $cap)))) + [$item])
| .schemaVersion = 1
| .updatedAt = $now
| .tickProof = false
