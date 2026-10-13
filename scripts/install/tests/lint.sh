#!/usr/bin/env bash
# Lint both install scripts: shellcheck, and PSScriptAnalyzer with Windows PowerShell 5.1
# compatibility checks (needs pwsh with the PSScriptAnalyzer module).
set -eu
cd "$(dirname "$0")/.."
shellcheck -s bash install.sh tests/run.sh tests/fastboot
pwsh -NoProfile -Command '
    $r = Invoke-ScriptAnalyzer -Path ./install.ps1 -Settings ./tests/PSScriptAnalyzerSettings.psd1 -Severity Information,Warning,Error
    $r | Format-Table -AutoSize RuleName, Line, Message -Wrap | Out-String -Width 160
    if ($r) { exit 1 }'
echo "lint ok"
