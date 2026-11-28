      !done && index($0, "\"$schema\"") && (i = index($0, old)) {
        $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1
      }
      { print }
