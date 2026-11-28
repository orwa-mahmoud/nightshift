def cl: gsub("[[:cntrl:]]"; " ");
( ["workspaces\t" + (if (.workspaces == null) then "no" else "yes" end)]
+ ((.scripts // {}) | keys | map("script-key\t" + (. | cl)))
) | .[]
