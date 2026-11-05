#!/usr/bin/env bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec uv run --frozen --project "${SOURCE_DIR}/../aioquic-interop" python "${SOURCE_DIR}/run_interop.py" "$@"
