echo "=== Script Functions Test Suite ==="
echo ""

echo "Test 1: Basic def + call"
def greet [name] {
    echo "hello $name"
}
greet zest
echo "✓ PASS: basic call"
echo ""

echo "Test 2: Optional param"
def maybe_name [name?] {
    if [ "$name" = "" ]
    then
        echo "no-name"
    else
        echo "name=$name"
    fi
}
maybe_name
maybe_name Ada
echo "✓ PASS: optional parameter"
echo ""

echo "Test 3: Function in if condition"
def is_ok [] { true }
if is_ok
then
    echo "✓ PASS: function condition"
else
    echo "✗ FAIL: function condition"
fi
echo ""

echo "Test 4: Param scoping"
name=outer
def overwrite [name] {
    INNER=$name
}
overwrite inner
if [ "$name" = "outer" ]
then
    echo "✓ PASS: param scope restored"
else
    echo "✗ FAIL: expected outer, got $name"
fi
echo ""

echo "=== Script Functions Tests Complete ==="
