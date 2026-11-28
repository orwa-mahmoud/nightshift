    function literal(s, from, to,    out, i) {
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return out s
    }
    {
      line = $0
      if (ENVIRON["NS_TEMPLATE_HAS_RUN"] == "1") line = literal(line, "$RUN", ENVIRON["NS_TEMPLATE_RUN"])
      line = literal(line, "$NIGHTSHIFT_WORKSPACE", ENVIRON["NS_TEMPLATE_WS"])
      print literal(line, "$NS", ENVIRON["NS_TEMPLATE_NS"])
    }
  
