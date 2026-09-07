#!/bin/sh
echo --% >/dev/null;: ' | Out-Null
<#'
case "${OS:-}:$(uname -s 2>/dev/null)" in
  Windows_NT:* | *:MINGW* | *:MSYS* | *:CYGWIN*)
    script="$CLAUDE_PLUGIN_ROOT/hooks/windows/session-start.ps1"
    command -v cygpath >/dev/null 2>&1 && script="$(cygpath -w "$script")"
    exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" -HostName claude
    ;;
esac
exec "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"
exit #>
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    "$env:CLAUDE_PLUGIN_ROOT\hooks\windows\session-start.ps1" -HostName claude
exit $LASTEXITCODE
