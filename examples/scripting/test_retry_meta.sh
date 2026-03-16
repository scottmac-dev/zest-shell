#!/usr/bin/env zest

echo "RETRY META"

FAILED=0
PATH=./zig-out/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


def mark_fail [msg] {
    echo "FAIL: $msg"
    FAILED=1
}

def mark_pass [msg] {
    echo "PASS: $msg"
}

def run_case [cmd] {
    main -c "$cmd" > /tmp/zest_retry_meta.out 2>&1
    LAST_STATUS=$?
}

def assert_status [label expected] {
    if [ "$LAST_STATUS" = "$expected" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (expected '$expected', got '$LAST_STATUS')"
    fi
}

def assert_contains [label needle] {
    grep -F "$needle" /tmp/zest_retry_meta.out > /dev/null 2>&1
    if [ "$?" = "0" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (missing '$needle')"
    fi
}

def assert_not_contains [label needle] {
    grep -F "$needle" /tmp/zest_retry_meta.out > /dev/null 2>&1
    if [ "$?" = "0" ]
    then
        mark_fail "$label (unexpected '$needle')"
    else
        mark_pass "$label"
    fi
}

run_case "retry 3 --delay 1ms false"
assert_status "retry should return final non-zero for false" "1"
assert_contains "retry should emit retry attempt logs by default" "retry: attempt"

run_case "retry 2 --delay 1ms --quiet false"
assert_status "retry --quiet should preserve final command exit code" "1"
assert_not_contains "retry --quiet should suppress per-attempt retry logs" "retry: attempt"

run_case "retry 2 --delay 1ms true"
assert_status "retry should return success when command succeeds immediately" "0"
assert_not_contains "retry should not log retries on immediate success" "retry: attempt"

run_case "retry for 1s --delay 1ms false"
assert_status "retry should support 'for <duration>' budget syntax" "1"
assert_contains "for-duration budget should retry on failure" "retry: attempt"

run_case "retry 2 --delay 1ms -- false"
assert_status "retry should reject optional -- command separator" "1"
assert_contains "retry should report invalid argument for -- separator" "Invalid argument"

run_case "retry 2 --delay 1ms --verbose false"
assert_status "retry should reject removed --verbose flag" "1"
assert_contains "retry should report invalid argument for --verbose" "Invalid argument"

run_case "retry 2 --delay 1ms { false }"
assert_status "retry should reject braced command body" "1"
assert_contains "retry should report invalid argument for braced body" "Invalid argument"

run_case "retry 5 --delay 1ms does-not-exist"
assert_status "retry should fail-fast for command-not-found" "127"
assert_not_contains "fail-fast command-not-found should not retry" "retry: attempt"

run_case "retry 3 --delay 1ms --on-exit 2 false"
assert_status "retry should preserve command exit when on-exit does not match" "1"
assert_not_contains "on-exit mismatch should prevent retries" "retry: attempt"

run_case "retry 3 --delay 1ms --except-exit 1 false"
assert_status "retry should preserve command exit when except-exit matches" "1"
assert_not_contains "except-exit match should prevent retries" "retry: attempt"

main -c "profile retry 2 --delay 1ms false" > /tmp/zest_retry_meta.out 2>&1
LAST_STATUS=$?
assert_status "profile + retry should execute and fail with final command status" "1"
assert_contains "profile should emit timing JSON" '"real_ms"'

rm -f /tmp/zest_retry_meta.out

if [ "$FAILED" = "0" ]
then
    echo "retry meta tests passed"
else
    echo "retry meta tests failed"
    false
fi
