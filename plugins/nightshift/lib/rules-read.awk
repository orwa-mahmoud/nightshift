# Strict-subset scanner for Nightshift rules.json. Not a general JSON parser.
# Allowed: the template's objects, strings, bools, integers, and string arrays.
# Anything else fails closed with a named reason.
#
# Modes:
#   rules    full rules.json shape
#   strings  one object of string values (toolDeny / session override)
#   policy   the shift policy snapshot, as the flat fact stream lib/policy.sh reads
#   defaults the remembered composition choices, as the same kind of fact stream
#   canon    one JSON document as compact canonical JSON: sorted keys, one line
#   pretty   the same document sorted and indented, for a file the owner reads
#   setblock the same, with one top-level key set to -v value; every other key survives
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
  if (mode == "canon" || mode == "pretty" || mode == "setblock") {
    jparse(".")
    skip_ws()
    if (i <= n) {
      fail("unexpected nesting")
    }
    if (mode == "setblock") {
      if (key == "") {
        fail("setblock needs a key")
      }
      setblock(key, value)
      printf "%s\n", pretty(".", "")
    } else if (mode == "pretty") {
      printf "%s\n", pretty(".", "")
    } else {
      printf "%s\n", canon(".")
    }
    exit
  }
  if (substr(src, i, 1) != "{") {
    # A document that is valid JSON but not an object is a fact the caller states,
    # not a read that failed: policy.sh names the field it wanted.
    if (mode == "policy" || mode == "defaults") {
      printf "x\t.\tnotobject\n"
      exit
    }
    fail("not a JSON object")
  }
  if (mode == "strings") {
    parse_string_object()
  } else if (mode == "policy" || mode == "defaults") {
    jparse(".")
  } else {
    parse_rules_object()
  }
  skip_ws()
  if (i <= n) {
    fail("unexpected nesting")
  }
  if (mode == "policy") {
    emit_policy()
  } else if (mode == "defaults") {
    emit_defaults()
  }
  printf "%s", outbuf
}

# ------------------------------------------------------------------ policy mode
#
# One shift policy snapshot as the same flat fact stream lib/policy.sh already reads from jq or
# python3, so an owner choice recorded for the night survives a host with neither. The document
# is parsed into paths first: a fact stream names absent keys as well as present ones, and only a
# finished parse knows which are which. Nothing here decides anything - policy.sh still owns
# validation, precedence and matching.

function jparse(path,    c, key, idx, first, keys, child) {
  skip_ws()
  c = peek()
  if (c == "{") {
    V_TYPE[path] = "object"
    i++
    skip_ws()
    if (peek() == "}") {
      i++
      V_KEYS[path] = ""
      return
    }
    keys = ""
    first = 1
    while (1) {
      skip_ws()
      if (peek() != "\"") {
        fail("not a JSON object")
      }
      parse_string_raw()
      key = decoded
      if (keys != "") {
        keys = keys "\t"
      }
      keys = keys scrub(key)
      skip_ws()
      if (peek() != ":") {
        fail("truncated JSON")
      }
      i++
      if (path == ".") {
        child = key
      } else {
        child = path "." key
      }
      jparse(child)
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
        V_KEYS[path] = keys
        return
      }
      fail("truncated JSON")
    }
  }
  if (c == "[") {
    V_TYPE[path] = "array"
    i++
    skip_ws()
    if (peek() == "]") {
      i++
      V_LEN[path] = 0
      return
    }
    idx = 0
    while (1) {
      jparse(path "[" idx "]")
      idx++
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
        V_LEN[path] = idx
        return
      }
      fail("truncated JSON")
    }
  }
  if (c == "\"") {
    parse_string_raw()
    V_TYPE[path] = "string"
    V_STR[path] = decoded
    V_RAW[path] = jenc(decoded)
    return
  }
  if (c == "t" || c == "f") {
    V_TYPE[path] = "boolean"
    V_RAW[path] = parse_bool()
    return
  }
  if (c == "n") {
    parse_null()
    V_TYPE[path] = "null"
    V_RAW[path] = "null"
    return
  }
  if (c == "-" || (c >= "0" && c <= "9")) {
    V_TYPE[path] = "number"
    V_RAW[path] = parse_signed()
    return
  }
  fail("unknown type")
}

function parse_signed(    start) {
  start = i
  if (peek() == "-") {
    i++
  }
  return substr(src, start, i - start) parse_number()
}

# A fact line holds exactly one fact, so a control character never travels in one.
function scrub(s,    j, c, o) {
  o = ""
  for (j = 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c < " " || c == "\177") {
      o = o " "
    } else {
      o = o c
    }
  }
  return o
}

# Whitespace runs collapse and the ends are trimmed, so one approved command compares equal
# however the document happened to wrap it.
function norm(s,    o, c, j, sp) {
  o = ""
  sp = 0
  for (j = 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\013" || c == "\014") {
      sp = 1
      continue
    }
    if (sp && o != "") {
      o = o " "
    }
    sp = 0
    o = o c
  }
  return o
}

function ptype(path) {
  if (path in V_TYPE) {
    return V_TYPE[path]
  }
  return "null"
}

function praw(path) {
  if (path in V_RAW) {
    return V_RAW[path]
  }
  return "null"
}

function plen(path) {
  if (ptype(path) == "array") {
    return V_LEN[path] + 0
  }
  return -1
}

function put(line) {
  outbuf = outbuf line "\n"
}

function emit_keys(path, label,    parts, count, j) {
  if (ptype(path) != "object") {
    return
  }
  count = split(V_KEYS[path], parts, "\t")
  for (j = 1; j <= count; j++) {
    if (parts[j] == "" && V_KEYS[path] == "") {
      continue
    }
    put("k\t" label "\t" parts[j])
  }
}

function emit_scalars(path, label, names,    parts, count, j, full) {
  count = split(names, parts, " ")
  for (j = 1; j <= count; j++) {
    if (label == ".") {
      full = parts[j]
    } else {
      full = label "." parts[j]
    }
    if (path == ".") {
      put("j\t" full "\t" praw(parts[j]))
    } else {
      put("j\t" full "\t" praw(path "." parts[j]))
    }
  }
}

# One line per remembered choice: whether the file states it, and what it states.
function emit_defaults(    parts, count, j, k) {
  if (ptype(".") != "object") {
    put("x\t.\tnotobject")
    return
  }
  count = split("schemaVersion verificationProfile hours toolingPolicy execution updatedAt", parts, " ")
  for (j = 1; j <= count; j++) {
    k = parts[j]
    if (k in V_TYPE) {
      put("d\t" k "\t1\t" praw(k))
    } else {
      put("d\t" k "\t0\tnull")
    }
  }
}

function emit_policy(    j, k, ap, cs, ws, cnt, val) {
  if (ptype(".") != "object") {
    put("x\t.\tnotobject")
    return
  }
  emit_keys(".", ".")
  emit_scalars(".", ".", "schemaVersion shiftId createdAt source deadlineEpoch verificationLevel toolingPolicy completionMode gatesDigest")

  put("ty\tbudgets\t" ptype("budgets"))
  if (ptype("budgets") == "object") {
    cnt = split(V_KEYS["budgets"], BK, "\t")
    for (j = 1; j <= cnt; j++) {
      if (BK[j] == "" && V_KEYS["budgets"] == "") {
        continue
      }
      put("b\t" BK[j] "\t" praw("budgets." BK[j]))
    }
  }

  put("ty\tselectedDebt\t" ptype("selectedDebt"))
  put("n\tselectedDebt\t" plen("selectedDebt"))
  for (j = 0; j < plen("selectedDebt"); j++) {
    if (ptype("selectedDebt[" j "]") == "string") {
      put("s\t" j "\ts\t" praw("selectedDebt[" j "]"))
    } else {
      put("s\t" j "\tx\t" praw("selectedDebt[" j "]"))
    }
  }

  put("ty\tallowances\t" ptype("allowances"))
  put("n\tallowances\t" plen("allowances"))
  for (j = 0; j < plen("allowances"); j++) {
    ap = "allowances[" j "]"
    put("ty\t" ap "\t" ptype(ap))
    emit_keys(ap, ap)
    emit_scalars(ap, ap, "category scope provenance")
    put("ty\t" ap ".plan\t" ptype(ap ".plan"))
    emit_keys(ap ".plan", ap ".plan")
    emit_scalars(ap ".plan", ap ".plan", "workTarget digest expiry")
    cs = ap ".plan.commands"
    put("ty\t" cs "\t" ptype(cs))
    put("n\t" cs "\t" plen(cs))
    for (k = 0; k < plen(cs); k++) {
      if (ptype(cs "[" k "]") == "string") {
        val = norm(V_STR[cs "[" k "]"])
        put("c\t" j "\t" k "\ts\t" scrub(val))
        put("q\t" j "\t" k "\t" jenc(val))
      } else {
        put("c\t" j "\t" k "\tx\t")
        put("q\t" j "\t" k "\tnull")
      }
    }
    ws = ap ".plan.writeSurface"
    put("ty\t" ws "\t" ptype(ws))
    for (k = 0; k < plen(ws); k++) {
      if (ptype(ws "[" k "]") == "string") {
        put("w\t" j "\t" k "\ts")
      } else {
        put("w\t" j "\t" k "\tx")
      }
    }
  }
}

# canon(path) — the parsed value at path as compact canonical JSON. Keys sort in byte order,
# which is what every other canonical writer here produces, so one document has one form
# whichever reader wrote it.
function canon(path,    t, out, keys, count, j, child, first) {
  t = ptype(path)
  if (t == "object") {
    count = split(V_KEYS[path], keys, "\t")
    if (V_KEYS[path] == "") {
      count = 0
    }
    sort_keys(keys, count)
    out = "{"
    first = 1
    for (j = 1; j <= count; j++) {
      if (path == ".") {
        child = keys[j]
      } else {
        child = path "." keys[j]
      }
      if (!first) {
        out = out ","
      }
      first = 0
      out = out cenc(keys[j]) ":" canon(child)
    }
    return out "}"
  }
  if (t == "array") {
    out = "["
    for (j = 0; j < V_LEN[path]; j++) {
      if (j > 0) {
        out = out ","
      }
      out = out canon(path "[" j "]")
    }
    return out "]"
  }
  if (t == "string") {
    return cenc(V_STR[path])
  }
  return praw(path)
}

function sort_keys(a, count,    j, k, tmp) {
  for (j = 2; j <= count; j++) {
    tmp = a[j]
    k = j - 1
    while (k >= 1 && a[k] > tmp) {
      a[k + 1] = a[k]
      k--
    }
    a[k + 1] = tmp
  }
}

# The canonical string form: the short escapes where JSON has one, and \uXXXX for every control
# character and every codepoint above ASCII, so one document has one form on any host. Bytes are
# read as UTF-8 here, which is why the callers run this under LC_ALL=C.
function cenc(s,    j, c, o, b, cb, code, len, k, ok, hi, lo) {
  o = "\""
  j = 1
  while (j <= length(s)) {
    c = substr(s, j, 1)
    b = ord(c)
    if (c == "\\") {
      o = o "\\\\"
      j++
      continue
    }
    if (c == "\"") {
      o = o "\\\""
      j++
      continue
    }
    if (c == "\n") {
      o = o "\\n"
      j++
      continue
    }
    if (c == "\r") {
      o = o "\\r"
      j++
      continue
    }
    if (c == "\t") {
      o = o "\\t"
      j++
      continue
    }
    if (c == "\b") {
      o = o "\\b"
      j++
      continue
    }
    if (c == "\f") {
      o = o "\\f"
      j++
      continue
    }
    if (b < 32) {
      o = o sprintf("\\u%04x", b)
      j++
      continue
    }
    if (b < 128) {
      o = o c
      j++
      continue
    }
    if (b >= 240) {
      len = 4
      code = b - 240
    } else if (b >= 224) {
      len = 3
      code = b - 224
    } else if (b >= 192) {
      len = 2
      code = b - 192
    } else {
      o = o c
      j++
      continue
    }
    ok = 1
    for (k = 1; k < len; k++) {
      cb = ord(substr(s, j + k, 1))
      if (cb < 128 || cb > 191) {
        ok = 0
        break
      }
      code = code * 64 + (cb - 128)
    }
    if (!ok) {
      o = o c
      j++
      continue
    }
    j += len
    if (code > 65535) {
      code -= 65536
      hi = 55296 + int(code / 1024)
      lo = 56320 + (code % 1024)
      o = o sprintf("\\u%04x\\u%04x", hi, lo)
    } else {
      o = o sprintf("\\u%04x", code)
    }
  }
  return o "\""
}

# pretty(path, indent) — the same sorted document a person reads: two spaces a level, one entry
# a line, and a string left as the UTF-8 it arrived as.
# setblock(k, text) — replace one top-level key with the document `text` holds, adding the key
# when the file does not carry it. Every other key keeps its own value, including one this
# version has never heard of: a plugin update fills settings in, it never takes them away.
function setblock(k, text,    save_src, save_n, save_i, keys, count, j, found) {
  drop_subtree(k)
  save_src = src
  save_n = n
  save_i = i
  src = text
  n = length(src)
  i = 1
  jparse(k)
  skip_ws()
  if (i <= n) {
    fail("the replacement value is not one JSON document")
  }
  src = save_src
  n = save_n
  i = save_i
  count = split(V_KEYS["."], keys, "\t")
  if (V_KEYS["."] == "") {
    count = 0
  }
  found = 0
  for (j = 1; j <= count; j++) {
    if (keys[j] == k) {
      found = 1
    }
  }
  if (!found) {
    if (V_KEYS["."] == "") {
      V_KEYS["."] = k
    } else {
      V_KEYS["."] = V_KEYS["."] "\t" k
    }
  }
}

# Everything the old value owned goes with it, so a shorter replacement cannot leave a field
# of the previous one behind.
function drop_subtree(k,    path) {
  for (path in V_TYPE) {
    if (path == k || substr(path, 1, length(k) + 1) == k "." ||
        substr(path, 1, length(k) + 1) == k "[") {
      delete V_TYPE[path]
      delete V_RAW[path]
      delete V_STR[path]
      delete V_KEYS[path]
      delete V_LEN[path]
    }
  }
}

function pretty(path, pad,    t, out, keys, count, j, child, inner) {
  t = ptype(path)
  inner = pad "  "
  if (t == "object") {
    count = split(V_KEYS[path], keys, "\t")
    if (V_KEYS[path] == "") {
      count = 0
    }
    if (count == 0) {
      return "{}"
    }
    sort_keys(keys, count)
    out = "{\n"
    for (j = 1; j <= count; j++) {
      if (path == ".") {
        child = keys[j]
      } else {
        child = path "." keys[j]
      }
      out = out inner penc(keys[j]) ": " pretty(child, inner)
      if (j < count) {
        out = out ","
      }
      out = out "\n"
    }
    return out pad "}"
  }
  if (t == "array") {
    if (V_LEN[path] == 0) {
      return "[]"
    }
    out = "[\n"
    for (j = 0; j < V_LEN[path]; j++) {
      out = out inner pretty(path "[" j "]", inner)
      if (j < V_LEN[path] - 1) {
        out = out ","
      }
      out = out "\n"
    }
    return out pad "]"
  }
  if (t == "string") {
    return penc(V_STR[path])
  }
  return praw(path)
}

# The readable string form: the short escapes JSON defines and \uXXXX for a control character,
# with every printable byte left as it stands.
function penc(s,    j, c, o, b) {
  o = "\""
  for (j = 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    b = ord(c)
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
    } else if (b < 32) {
      o = o sprintf("\\u%04x", b)
    } else {
      o = o c
    }
  }
  return o "\""
}

function ord(c,    j) {
  if (ORDINIT == 0) {
    for (j = 0; j < 256; j++) {
      ORD[sprintf("%c", j)] = j
    }
    ORDINIT = 1
  }
  return ORD[c]
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
    # JSON requires U+0000 through U+001F to be escaped inside a string. Accepting a raw one
    # would make this reader answer where every other JSON reader refuses, and a host with a
    # parser and a host without would then disagree about whether a file is valid at all.
    if (c < " ") {
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
