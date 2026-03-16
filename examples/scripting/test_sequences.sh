#!/usr/bin/env bash
# ; colon will run both regardless
echo "step 1"; echo "step 2"
false; echo "runs anyway"

# && only runs if first succeeds
true && echo "success"
false && echo "won't run"

# || only runs if prev fails
true || echo "won't run"
false || echo "fallback"
cat doesnt-exist.txt || echo "File not found"
