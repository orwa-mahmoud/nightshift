    index($0, ENVIRON["NS_OWNER"]) == 1 { who = "owner"; if (shown++) print ""; print; next }
    index($0, ENVIRON["NS_WORKER"]) == 1 { who = "worker"; next }
    who == "owner" { print }
  
