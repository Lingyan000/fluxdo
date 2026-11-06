#!/bin/bash
set -euo pipefail

# Keep the pinned simulator's setup and scenarios. Its kill-only traps let PID 1
# exit before dumpcap flushes; join capture children before the container stops.
# Also allow the final kernel packet batch to reach dumpcap before signalling it.
# dumpcap uses a 250 ms capture timeout; stopping its loop does not drain that
# batch. One second leaves scheduling margin within the 10 s container grace.
script=$(<./run.sh)
for signal in INT TERM; do
    original="trap \"kill -SIG${signal} \$PID\" ${signal}"
    if [[ "$script" != *"$original"* ]]; then
        echo "unsupported simulator shutdown handler: $signal" >&2
        exit 1
    fi
    replacement="trap \"trap '' INT TERM; sleep 1; kill -SIG${signal} \$PID 2>/dev/null || true; wait\" ${signal}"
    script=${script/"$original"/"$replacement"}
done
exec bash -c "$script"
