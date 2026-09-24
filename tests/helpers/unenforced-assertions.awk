# Print every `[[ ]]`, `(( ))` or `!` statement in a Bats file that does not end in an enforcing
# `||` branch, as file:line: statement. Bash 3.2 lets a failing `[[ ]]` or `(( ))` pass unless it
# is the test's last command, and no bash fails a test on a `!` statement, so each one must end in
# `|| false`, `|| return`, `|| exit` or a `|| { ...; }` group. Heredoc bodies are data and skipped.

function flush() {
  if (stmt != "") {
    tail = stmt
    sub(/[ \t]+$/, "", tail)
    if (tail !~ /\|\|[ \t]*(false|return([ \t]+[0-9]+)?|exit([ \t]+[0-9]+)?|\{.*\}|\{)$/)
      print FILENAME ":" start ": " first
  }
  stmt = ""
}

FNR == 1 { flush(); heredoc = "" }

{
  line = $0
  if (heredoc != "") {
    body = line
    sub(/^\t+/, "", body)
    if (body == heredoc) heredoc = ""
    next
  }

  # A heredoc operator is followed by a blank, a redirection, a pipe or the end of the line; one
  # inside a printf string is followed by a literal \n and stays text.
  probe = line
  gsub(/<<</, "", probe)
  opens = ""
  if (match(probe, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?([ \t>|);&]|$)/)) {
    opens = substr(probe, RSTART, RLENGTH)
    sub(/[ \t>|);&]$/, "", opens)
    gsub(/<<-?[ \t]*|['"]/, "", opens)
  }

  if (stmt != "") {
    stmt = stmt "\n" line
  } else if (line ~ /^[ \t]*(\[\[|\(\(|!)[ \t]/) {
    stmt = line
    start = FNR
    first = line
    sub(/^[ \t]+/, "", first)
    kind = substr(first, 1, 2)
  }

  if (stmt != "") {
    more = (line ~ /\\$/)
    if (kind == "[[" && stmt !~ / \]\]/) more = 1
    if (kind == "((" && stmt !~ /\)\)/) more = 1
    if (!more) flush()
  }

  if (opens != "") heredoc = opens
}

END { flush() }
