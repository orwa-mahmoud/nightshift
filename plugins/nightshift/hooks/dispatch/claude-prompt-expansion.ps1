#!/bin/sh
echo --% >/dev/null;: ' | Out-Null
<#'
# Sourced by the host, so $0 is the shell. The plugin root is the variable the command already set.
_ns_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$_ns_root" ]; then
  case "$0" in
    */*)
      _ns_dir=${0%/*}
      _ns_root="$(CDPATH= cd -P "$_ns_dir/../.." && pwd)"
      ;;
  esac
fi
if [ -n "$_ns_root" ]; then
  # shellcheck source=plugins/nightshift/lib/ownership.sh
  . "$_ns_root/lib/ownership.sh"
  ns_copy_serves_host "$_ns_root" claude || exit 0
fi
case "${OS:-}:$(uname -s 2>/dev/null)" in
  Windows_NT:* | *:MINGW* | *:MSYS* | *:CYGWIN*)
    script="$CLAUDE_PLUGIN_ROOT/hooks/windows/prompt-submit.ps1"
    command -v cygpath >/dev/null 2>&1 && script="$(cygpath -w "$script")"
    exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" -HostName claude
    ;;
esac
exec "$CLAUDE_PLUGIN_ROOT/hooks/prompt-expansion.sh"
exit #>
$nsRoot = $env:CLAUDE_PLUGIN_ROOT
if ([string]::IsNullOrEmpty($nsRoot)) { $nsRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath }
Import-Module (Join-Path $nsRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
if (-not (Test-NSCopyServesHost $nsRoot 'claude')) { exit 0 }
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\hooks\windows\prompt-submit.ps1" -HostName claude
exit $LASTEXITCODE
