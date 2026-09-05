# Strict-subset scanner for Nightshift rules.json. Not a general JSON parser.
# Allowed: the template's objects, strings, bools, integers, and string arrays.
# Anything else fails closed with a named reason.
#
# Modes:
#   rules    full rules.json shape
#   strings  one object of string values (toolDeny / session override)
#   unquote  one JSON string on stdin, decoded text on stdout

{
  src = src $0
  if (mode != "unquote") {
    src = src "\n"
  }
}

END {
  if (mode == "unquote") {
    if (unquote_one(src) == 0) {
      printf "%s", decoded
    }
    exit
  }
  n = length(src)
  i = 1
  skip_ws()
  if (i > n) {
    fail("empty document")
  }
  if (substr(src, i, 1) != "{") {
    fail("not a JSON object")
  }
  if (mode == "strings") {
    parse_string_object()
  } else {
    parse_rules_object()
  }
  skip_ws()
  if (i <= n) {
    fail("unexpected nesting")
  }
  printf "%s", outbuf
}

function fail(reason) {
  print "ERR\t" reason
  exit 1
}

function peek() {
  return substr(src, i, 1)
}

function skip_ws(    c, n2) {
  while (i <= n) {
    c = substr(src, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") {
      i++
      continue
    }
    break
  }
  if (i > n) {
    return
  }
  c = substr(src, i, 1)
  if (c == "#") {
    fail("comment")
  }
  if (c == "/") {
    n2 = substr(src, i + 1, 1)
    if (n2 == "/" || n2 == "*") {
      fail("comment")
    }
  }
}

function hexval(h,    j, c, v, d) {
  d = 0
  for (j = 1; j <= length(h); j++) {
    c = substr(tolower(h), j, 1)
    v = index("0123456789abcdef", c) - 1
    if (v < 0) {
      return -1
    }
    d = d * 16 + v
  }
  return d
}

function utf8chr(code,    b1, b2, b3) {
  if (code < 128) {
    return sprintf("%c", code)
  }
  if (code < 2048) {
    return sprintf("%c%c", 192 + int(code / 64), 128 + (code % 64))
  }
  b1 = 224 + int(code / 4096)
  b2 = 128 + (int(code / 64) % 64)
  b3 = 128 + (code % 64)
  return sprintf("%c%c%c", b1, b2, b3)
}

function parse_string_raw(    c, e, hex, code, out) {
  if (peek() != "\"") {
    fail("invalid string")
  }
  i++
  out = ""
  while (i <= n) {
    c = substr(src, i, 1)
    if (c == "\"") {
      i++
      decoded = out
      return 0
    }
    if (c == "\n" || c == "\r") {
      fail("invalid string")
    }
    if (c == "\\") {
      i++
      if (i > n) {
        fail("invalid string")
      }
      e = substr(src, i, 1)
      if (e == "\"" || e == "\\" || e == "/") {
        out = out e
      } else if (e == "b") {
        out = out "\b"
      } else if (e == "f") {
        out = out "\f"
      } else if (e == "n") {
        out = out "\n"
      } else if (e == "r") {
        out = out "\r"
      } else if (e == "t") {
        out = out "\t"
      } else if (e == "u") {
        hex = substr(src, i + 1, 4)
        if (length(hex) < 4) {
          fail("invalid string")
        }
        code = hexval(hex)
        if (code < 0) {
          fail("invalid string")
        }
        out = out utf8chr(code)
        i += 4
      } else {
        fail("invalid string")
      }
      i++
      continue
    }
    out = out c
    i++
  }
  fail("invalid string")
}

function jenc(s,    j, c, o) {
  o = "\""
  for (j = 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c == "\\") {
      o = o "\\\\"
    } else if (c == "\"") {
      o = o "\\\""
    } else if (c == "\n") {
      o = o "\\n"
    } else if (c == "\r") {
      o = o "\\r"
    } else if (c == "\t") {
      o = o "\\t"
    } else if (c == "\b") {
      o = o "\\b"
    } else if (c == "\f") {
      o = o "\\f"
    } else {
      o = o c
    }
  }
  return o "\""
}

function unquote_one(text,    save_src, save_n, save_i) {
  save_src = src
  save_n = n
  save_i = i
  src = text
  n = length(src)
  i = 1
  skip_ws()
  if (parse_string_raw() != 0) {
    src = save_src
    n = save_n
    i = save_i
    return 1
  }
  src = save_src
  n = save_n
  i = save_i
  return 0
}

function emit(p1, p2, p3, typ, val) {
  outbuf = outbuf p1 "\t" p2 "\t" p3 "\t" typ "\t" val "\n"
}

function parse_number(    c, start, token) {
  start = i
  c = peek()
  if (c == "-") {
    fail("unknown type")
  }
  if (c == "0") {
    i++
    if (i <= n) {
      c = peek()
      if (c >= "0" && c <= "9") {
        fail("unknown type")
      }
      if (c == "." || c == "e" || c == "E") {
        fail("unknown type")
      }
    }
    return "0"
  }
  if (c < "1" || c > "9") {
    fail("unknown type")
  }
  i++
  while (i <= n) {
    c = peek()
    if (c < "0" || c > "9") {
      break
    }
    i++
  }
  if (i <= n) {
    c = peek()
    if (c == "." || c == "e" || c == "E") {
      fail("unknown type")
    }
  }
  token = substr(src, start, i - start)
  return token
}

function parse_bool(    c) {
  c = peek()
  if (c == "t") {
    if (substr(src, i, 4) != "true") {
      fail("unknown type")
    }
    i += 4
    return "true"
  }
  if (c == "f") {
    if (substr(src, i, 5) != "false") {
      fail("unknown type")
    }
    i += 5
    return "false"
  }
  fail("unknown type")
}

function parse_string_array(p1,    c, idx, first) {
  i++
  skip_ws()
  if (peek() == "]") {
    i++
    emit(p1, "", "", "a", "")
    return
  }
  emit(p1, "", "", "a", "")
  idx = 0
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "]") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("unknown type")
    }
    parse_string_raw()
    emit(p1, idx, "", "s", jenc(decoded))
    idx++
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      first = 0
      skip_ws()
      if (peek() == "]") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "]") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_string_object(    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    if (peek() != "\"") {
      fail("unknown type")
    }
    parse_string_raw()
    emit(key, "", "", "s", jenc(decoded))
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_rules_object(    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    parse_top_value(key)
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_top_value(key,    c) {
  c = peek()
  if (c == "\"") {
    parse_string_raw()
    emit(key, "", "", "s", jenc(decoded))
    return
  }
  if (c == "t" || c == "f") {
    emit(key, "", "", "b", parse_bool())
    return
  }
  if (c >= "0" && c <= "9") {
    emit(key, "", "", "n", parse_number())
    return
  }
  if (c == "[") {
    parse_string_array(key)
    return
  }
  if (c == "{") {
    if (key == "toolDeny") {
      emit(key, "", "", "o", "")
      parse_named_string_object(key)
      return
    }
    if (key == "elevation") {
      emit(key, "", "", "o", "")
      parse_elevation()
      return
    }
    if (key == "retention") {
      emit(key, "", "", "o", "")
      parse_retention()
      return
    }
    if (key == "shift" || key == "handoff" || key == "archive") {
      emit(key, "", "", "o", "")
      parse_settings_object(key)
      return
    }
    fail("unexpected nesting")
  }
  if (c == "n") {
    fail("unknown type")
  }
  if (c == "-") {
    fail("unknown type")
  }
  fail("unknown type")
}

function parse_named_string_object(p1,    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    if (peek() != "\"") {
      fail("unexpected nesting")
    }
    parse_string_raw()
    emit(p1, key, "", "s", jenc(decoded))
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_elevation(    c, cat, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    cat = decoded
    if (index(cat, "\t") || index(cat, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    if (peek() != "{") {
      fail("unexpected nesting")
    }
    emit("elevation", cat, "", "o", "")
    parse_named_string_object_pair("elevation", cat)
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_named_string_object_pair(p1, p2,    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    if (peek() != "\"") {
      fail("unexpected nesting")
    }
    parse_string_raw()
    emit(p1, p2, key, "s", jenc(decoded))
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_null() {
  if (substr(src, i, 4) != "null") {
    fail("unknown type")
  }
  i += 4
}

# A settings block: one level of named values, each a string, integer, bool, null,
# or the string array the schema declares. Deeper nesting still fails closed - this
# reads the shape the schema describes, never arbitrary JSON.
function parse_settings_object(p1,    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    c = peek()
    if (c == "\"") {
      parse_string_raw()
      emit(p1, key, "", "s", jenc(decoded))
    } else if (c == "t" || c == "f") {
      emit(p1, key, "", "b", parse_bool())
    } else if (c >= "0" && c <= "9") {
      emit(p1, key, "", "n", parse_number())
    } else if (c == "n") {
      parse_null()
      emit(p1, key, "", "z", "null")
    } else if (c == "[") {
      parse_settings_array(p1, key)
    } else {
      fail("unexpected nesting")
    }
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_settings_array(p1, p2,    c, idx, first) {
  i++
  skip_ws()
  emit(p1, p2, "", "a", "")
  if (peek() == "]") {
    i++
    return
  }
  idx = 0
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "]") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("unknown type")
    }
    parse_string_raw()
    emit(p1, p2, idx, "s", jenc(decoded))
    idx++
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "]") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "]") {
      i++
      return
    }
    fail("truncated JSON")
  }
}

function parse_retention(    c, key, first) {
  i++
  skip_ws()
  if (peek() == "}") {
    i++
    return
  }
  first = 1
  while (1) {
    skip_ws()
    c = peek()
    if (c == "}") {
      if (first == 0) {
        fail("trailing comma")
      }
      i++
      return
    }
    if (c != "\"") {
      fail("not a JSON object")
    }
    parse_string_raw()
    key = decoded
    if (index(key, "\t") || index(key, "\n")) {
      fail("unexpected nesting")
    }
    skip_ws()
    if (peek() != ":") {
      fail("truncated JSON")
    }
    i++
    skip_ws()
    c = peek()
    if (c < "0" || c > "9") {
      fail("unexpected nesting")
    }
    emit("retention", key, "", "n", parse_number())
    first = 0
    skip_ws()
    c = peek()
    if (c == ",") {
      i++
      skip_ws()
      if (peek() == "}") {
        fail("trailing comma")
      }
      continue
    }
    if (c == "}") {
      i++
      return
    }
    fail("truncated JSON")
  }
}
