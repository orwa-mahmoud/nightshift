  (.toolDeny | type) == "object"
  and (.toolDeny | has("AskUserQuestion"))
  and (.toolDeny | has("request_user_input"))
  and (.toolDeny | has("AskQuestion"))
  and (.toolDeny.AskUserQuestion | type) == "string"
  and (.toolDeny.request_user_input | type) == "string"
  and (.toolDeny.AskQuestion | type) == "string"
