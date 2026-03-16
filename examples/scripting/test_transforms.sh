#!/usr/bin/env zest

echo "TRANSFORMS"

FAILED=0


def mark_fail [msg] {
    echo "FAIL: $msg"
    FAILED=1
}

def mark_pass [msg] {
    echo "PASS: $msg"
}

def assert_last_status_ok [label] {
    if [ "$LAST_STATUS" = "0" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (status=$LAST_STATUS)"
    fi
}

def assert_out_equals [label expected] {
    grep -Fx "$expected" /tmp/zest_transforms_test.out > /dev/null 2>&1
    if [ "$?" = "0" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (expected '$expected')"
    fi
}

echo -n 'a b c' | split ' ' | map upper | join ',' > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "map command exits successfully"
assert_out_equals "map output" "A,B,C"

help --all | where .name == read | count > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "where command exits successfully"
assert_out_equals "where output" "1"

echo -n 'aa b ccc' | split ' ' | map len | reduce sum > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "reduce command exits successfully"
assert_out_equals "reduce output" "6"

read test_files/txt/numbers.txt | lines | count > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "lines/count command exits successfully"
assert_out_equals "lines/count output" "10000"

echo -n 'x,y,z' | split ',' | join '|' > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "split command exits successfully"
assert_out_equals "split output" "x|y|z"

echo -n 'x,y,z' | split ',' | join '-' > /tmp/zest_transforms_test.out 2>&1
LAST_STATUS=$?
assert_last_status_ok "join command exits successfully"
assert_out_equals "join output" "x-y-z"

rm -f /tmp/zest_transforms_test.out

if [ "$FAILED" = "0" ]
then
    echo "All transform tests passed"
else
    echo "Transform tests failed"
    false
fi
