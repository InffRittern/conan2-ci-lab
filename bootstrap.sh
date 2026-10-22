#!/usr/bin/env bash
# Entry point for the Linux (bash) variant. See scripts/linux/.
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/scripts/linux/bootstrap.sh" "$@"
