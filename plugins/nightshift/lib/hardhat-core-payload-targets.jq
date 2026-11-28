          def string_values: .. | strings;
          .tool_input
          | ..
          | objects
          | . as $object
          | (
              (
                $object
                | to_entries[]
                | select(.key | test("((^|_)(path|filepath|file|filename|directory|dir|uri|name)$|^(target|destination|dest|source|src)$)"; "i"))
                | .value
                | string_values
                | if contains("\n") then @base64 | "P\t\(.)" else "p\t\(.)" end
              ),
              (
                $object
                | to_entries[]
                | select(.key | test("(^|_)(command|cmd|script)$"; "i"))
                | .value
                | string_values
                | if contains("\n") then @base64 | "C\t\(.)" else "c\t\(.)" end
              ),
              (
                [$object | to_entries[] | select(.key | test("^(directory|dir)$"; "i")) | .value | string_values] as $dirs
                | [$object | to_entries[] | select(.key | test("^(name|filename|file)$"; "i")) | .value | string_values] as $names
                | $dirs[] as $dir
                | $names[] as $name
                | "\($dir)/\($name)"
                | if contains("\n") then @base64 | "P\t\(.)" else "p\t\(.)" end
              )
            )
        
