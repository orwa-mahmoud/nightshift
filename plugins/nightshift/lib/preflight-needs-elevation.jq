.settings | to_entries[]
    | select(.key | startswith("elevation."))
    | (.key | ltrimstr("elevation.")) + "\t" + .value.value
