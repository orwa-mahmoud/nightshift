    ($p[0].shiftDefaults // {}) as $sd
    | $base
    + (if ($sd | has("verificationProfile")) then {verificationProfile: $sd.verificationProfile} else {} end)
    + (if ($sd | has("hours")) then {hours: $sd.hours} else {} end)
    + (if ($sd | has("toolingPolicy")) then {toolingPolicy: $sd.toolingPolicy} else {} end)
    + (if ($sd | has("execution")) then {execution: $sd.execution} else {} end)
    + {schemaVersion: 1, updatedAt: $now}
  
