      type == "object"
      and .schemaVersion == 1
      and (.verificationProfile as $v | (["fast","balanced","strict","custom"] | index($v)) != null)
      and (.hours == null or (.hours | type == "number"))
      and (.toolingPolicy as $t | (["existing-tools","review-missing","auto-add"] | index($t)) != null)
      and (.execution as $e | (["review-first","run-direct"] | index($e)) != null)
    
