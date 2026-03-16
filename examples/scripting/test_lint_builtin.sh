#!/usr/bin/env zest

echo "LINT BUILTIN"

FAILED=0
PATH=./zig-out/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

def mark_fail [msg] {
    echo "FAIL: $msg"
    FAILED=1
}

def mark_pass [msg] {
    echo "PASS: $msg"
}

def assert_status [label expected actual] {
    if [ "$expected" = "$actual" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (expected '$expected', got '$actual')"
    fi
}

def assert_file_contains [label path needle] {
    grep -F "$needle" "$path" > /dev/null 2>&1
    if [ "$?" = "0" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (missing '$needle')"
    fi
}

printf '#!/usr/bin/env zest\ndef greet [name:text] {\n  GREETING=$name\n}\ngreet zest\n' > /tmp/zest_lint_valid.sh
printf 'echo hello\n' > /tmp/zest_lint_no_shebang.sh
printf '#!/usr/bin/env zest\ndef needs_int [x:int] {\n  OUT=$x\n}\nneeds_int hello\nif true\n  echo nope\n' > /tmp/zest_lint_invalid.sh
printf '#!/usr/bin/env zest\necho hi\n' > /tmp/zest_lint_wrong_ext.txt

main -c "lint /tmp/zest_lint_valid.sh" > /tmp/zest_lint_valid.out 2>&1
STATUS=$?
assert_status "lint should pass a valid script" "0" "$STATUS"

main -c "lint /tmp/zest_lint_no_shebang.sh" > /tmp/zest_lint_no_shebang.out 2>&1
STATUS=$?
assert_status "lint should allow scripts without a shebang" "0" "$STATUS"

main -c "lint /tmp/zest_lint_invalid.sh" > /tmp/zest_lint_invalid.out 2>&1
STATUS=$?
assert_status "lint should fail syntax/type issues" "1" "$STATUS"
assert_file_contains "lint should report typed arg mismatch" "/tmp/zest_lint_invalid.out" "zest_lint_invalid.sh 5:1 TypeMismatch hello"
assert_file_contains "lint should report unterminated if" "/tmp/zest_lint_invalid.out" "zest_lint_invalid.sh 6:1 InvalidSyntax if"

main -c "lint /tmp/zest_lint_wrong_ext.txt" > /tmp/zest_lint_wrong_ext.out 2>&1
STATUS=$?
assert_status "lint should reject non-.sh files" "1" "$STATUS"
assert_file_contains "lint should report extension rule" "/tmp/zest_lint_wrong_ext.out" "zest_lint_wrong_ext.txt 1:1 InvalidSyntax .sh"

rm -f /tmp/zest_lint_valid.sh /tmp/zest_lint_no_shebang.sh /tmp/zest_lint_invalid.sh /tmp/zest_lint_wrong_ext.txt
rm -f /tmp/zest_lint_valid.out /tmp/zest_lint_no_shebang.out /tmp/zest_lint_invalid.out /tmp/zest_lint_wrong_ext.out

if [ "$FAILED" = "0" ]
then
    echo "lint builtin tests passed"
else
    echo "lint builtin tests failed"
    false
fi
