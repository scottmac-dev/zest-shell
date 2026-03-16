echo "=== Typed Script Functions Smoke Test ==="
echo ""

FAILED=0

def assert_eq [label expected actual] {
    if [ "$expected" = "$actual" ]
    then
        echo "✓ PASS: $label"
    else
        echo "✗ FAIL: $label (expected '$expected', got '$actual')"
        FAILED=1
    fi
}

def assert_nonzero [label code] {
    if [ "$code" = "0" ]
    then
        echo "✗ FAIL: $label (expected non-zero exit)"
        FAILED=1
    else
        echo "✓ PASS: $label"
    fi
}

echo "Test 1: typed primitive args + default any inference"
def typed_ok [i: int s: string f: float b: bool x] {
    OUT_I=$i
    OUT_S=$s
    OUT_F=$f
    OUT_B=$b
    OUT_X=$x
}
typed_ok 42 zest 3.5 true +1
assert_eq "int parsed" "42" "$OUT_I"
assert_eq "string parsed" "zest" "$OUT_S"
assert_eq "float parsed" "3.5" "$OUT_F"
assert_eq "bool parsed" "true" "$OUT_B"
assert_eq "any inferred (+1 -> 1)" "1" "$OUT_X"
echo ""

echo "Test 2: optional typed arg binds empty when omitted"
def maybe_count [n?: int] {
    MAYBE_N=$n
}
maybe_count
assert_eq "optional typed missing => empty string" "" "$MAYBE_N"
echo ""

echo "Test 3: list/map typed args from JSON text"
def typed_struct [items: list meta: map] {
    OUT_LIST=$items
    OUT_MAP=$meta
}
typed_struct '[1,2]' '{"a":1}'
assert_eq "list typed" "[1, 2]" "$OUT_LIST"
assert_eq "map typed" '{"a": 1}' "$OUT_MAP"
echo ""

echo "Test 4: type mismatch returns non-zero and body does not run"
OUT_BAD=unset
def needs_int [n: int] {
    OUT_BAD=called
}
needs_int nope
STATUS_BAD=$?
assert_nonzero "typed mismatch exit code" "$STATUS_BAD"
assert_eq "typed mismatch does not execute body" "unset" "$OUT_BAD"
echo ""

if [ "$FAILED" = "0" ]
then
    echo "=== Typed Function Smoke Test: PASS ==="
else
    echo "=== Typed Function Smoke Test: FAIL ==="
fi
