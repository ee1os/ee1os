#!/usr/bin/env bash
# Tests of the fork report scripts (ledger.py, fork_report.py, fork_report_html.py).
set -euo pipefail
cd "$(dirname "$0")"
exec python3 -I -m unittest discover -s . -p 'test_*.py' "$@"
