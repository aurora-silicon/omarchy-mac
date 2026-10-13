#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/build-app.sh" recovery "${1:-build-recovery}"
