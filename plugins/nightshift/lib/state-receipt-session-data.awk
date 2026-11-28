    /^<!-- usage -->$/ { if (seen++) exit; usage = 1; next }
    /^<!-- \/usage -->$/ { if (usage) exit }
    usage && /^<!-- session-data$/ { on = 1; next }
    on && /^-->$/ { exit }
    on && NF { print }
  
