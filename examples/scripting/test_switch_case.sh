echo "=== Switch Case Test Suite ==="
echo ""

FAILED=0

def mark_fail [msg] {
    echo "FAIL: $msg"
    FAILED=1
}

def mark_pass [msg] {
    echo "PASS: $msg"
}

def assert_eq [label expected actual] {
    if [ "$expected" = "$actual" ]
    then
        mark_pass "$label"
    else
        mark_fail "$label (expected '$expected', got '$actual')"
    fi
}

echo "Test 1: matching case executes"
VALUE=2

switch [$VALUE] {
    case 1:
        RESULT=one
        break;
    case 2:
        RESULT=two
        break;
    default:
        RESULT=defaulted
}
assert_eq "switch case equality match" "two" "$RESULT"
echo ""

echo "Test 2: default executes when no case matches"
switch [404]
{
    case 200:
        STATUS=ok
        break;
    default:
        STATUS=missing
}
assert_eq "switch default fallback" "missing" "$STATUS"
echo ""

echo "Test 3: break exits switch, not outer for loop"
COUNT=0
for item in a b
do
    switch [$item] {
        case a:
            break;
        case b:
            COUNT=1
            break;
    }
done
assert_eq "switch break does not break for loop" "1" "$COUNT"
echo ""

if [ "$FAILED" = "0" ]
then
    echo "switch case tests passed"
else
    echo "switch case tests failed"
    false
fi
