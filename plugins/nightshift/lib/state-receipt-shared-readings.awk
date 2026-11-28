FNR == NR { if (/^<!-- usage -->/) gated = 1; next }
    FNR == 1 { on = !gated }
    /^<!-- usage -->/ { on = 1; next } /^<!-- \/usage -->/ { on = 0 }
    on && /^<!-- shared [^ ]+( [0-9-]+)+ -->$/ && NF == 9 { print $3, $4, $5, $6, $7, $8 }
