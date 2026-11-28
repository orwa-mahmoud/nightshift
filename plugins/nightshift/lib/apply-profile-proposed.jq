  def fill:
    ($cur)
    + (
        $p[0].rules
        | to_entries
        | map(select(.key as $k | $cur | has($k) | not))
        | from_entries
      );
  # Replace rebuilds the guards from the shipped template: the top-level settings and the toolDeny
  # and elevation blocks. Every other block is an owner preference no guard profile is asking
  # about (shift defaults, receipts, catalogs, retention and the rest), so it is kept as it is.
  def replace:
    $t[0]
    + ($cur | to_entries
       | map(select((.value | type) == "object" and .key != "toolDeny" and .key != "elevation"))
       | from_entries)
    + $p[0].rules
    + (
        if ($cur["$schema"] | type) == "string" and ($cur["$schema"] | length) > 0
        then {"$schema": $cur["$schema"]}
        else {}
        end
      );
  if env.PROFILE_MODE == "fill" then fill else replace end
