#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/build-apple-core.sh" ios-simulator "$@"
