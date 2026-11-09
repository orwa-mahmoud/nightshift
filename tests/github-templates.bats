# GitHub rejects an issue form that is not valid YAML, so every form must parse.

@test "every issue form is valid YAML with a name and a body" {
  for f in "$BATS_TEST_DIRNAME"/../.github/ISSUE_TEMPLATE/*.yml; do
    case "${f##*/}" in config.yml) continue ;; esac
    ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); exit(d.is_a?(Hash) && d["name"].is_a?(String) && d["body"].is_a?(Array) ? 0 : 1)' "$f" \
      || { echo "invalid issue form: $f"; return 1; }
  done
}
