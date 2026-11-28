function edge(c) { return (c == "") ? 1 : (index(DELIM, c) > 0) }
BEGIN { DELIM = " \t\r=<>[~!\"," sprintf("%c", 39); n = length(tok); ok = 0 }
{
  s = $0
  p = 0
  while (1) {
    i = index(substr(s, p + 1), tok)
    if (i == 0) break
    i = p + i
    if (edge(i == 1 ? "" : substr(s, i - 1, 1)) && edge(substr(s, i + n, 1))) {
      ok = 1
      exit
    }
    p = i
  }
}
END { exit ok ? 0 : 1 }
