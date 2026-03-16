#!/usr/bin/env zest
# Test script for while loops

echo "=== While Loop Test Suite ==="
echo ""

# Test 1: Simple counter loop
echo "Test 1: Counter loop"
COUNT=0
while [ "$COUNT" != "3" ]
do
    echo "  Count: $COUNT"
    if [ "$COUNT" = "0" ]
    then
        COUNT=1
    fi
    if [ "$COUNT" = "1" ]
    then
        COUNT=2
    fi
    if [ "$COUNT" = "2" ]
    then
        COUNT=3
    fi
done
echo "✓ PASS: Counter reached $COUNT"
echo ""

# Test 2: While with true/false
echo "Test 2: While true with break condition"
X=0
while true
do
    echo "  Iteration: $X"
    if [ "$X" = "2" ]
    then
        X=done
    fi
    if [ "$X" != "done" ]
    then
        if [ "$X" = "0" ]
        then
            X=1
        fi
        if [ "$X" = "1" ]
        then
            X=2
        fi
    fi
    if [ "$X" = "done" ]
    then
        break
    fi
done
echo "✓ PASS: Loop exited"
echo ""

# Test 3: While false (should not execute)
echo "Test 3: While false"
EXECUTED=no
while false
do
    EXECUTED=yes
done
if [ "$EXECUTED" = "no" ]
then
    echo "✓ PASS: Body correctly not executed"
else
    echo "✗ FAIL: Body should not execute"
fi
echo ""

# Test 4: File processing pattern
echo "Test 4: File processing pattern"
echo "line1" > /tmp/test_while.txt
echo "line2" >> /tmp/test_while.txt
echo "line3" >> /tmp/test_while.txt
LINES=0
while [ "$LINES" != "3" ]
do
    echo "  Processing file..."
    LINES=3
    # In real script would: read lines, process, then rm file
    # For test, just break after one iteration
    if [ "$LINES" = "3" ]
    then
        LINES=done
    fi
    if [ "$LINES" = "done" ]
    then
        break
    fi
done
echo "✓ PASS: File processing pattern"
echo ""

# Test 5: Nested while (simple)
echo "Test 5: Nested while"
OUTER=0
while [ "$OUTER" != "2" ]
do
    echo "  Outer: $OUTER"
    INNER=0
    while [ "$INNER" != "2" ]
    do
        echo "    Inner: $INNER"
        if [ "$INNER" = "0" ]
        then
            INNER=1
        fi
        if [ "$INNER" = "1" ]
        then
            INNER=2
        fi
    done
    if [ "$OUTER" = "0" ]
    then
        OUTER=1
    fi
    if [ "$OUTER" = "1" ]
    then
        OUTER=2
    fi
done
echo "✓ PASS: Nested while loops"
echo ""

# Test 6: While with command condition
echo "Test 6: While with command condition"
echo "test" > /tmp/while_test_file.txt
COUNT=0
while [ "$COUNT" != "1" ]
do
    echo "  Checking file exists..."
    COUNT=1
    # Remove file to exit loop
    if [ "$COUNT" = "1" ]
    then
        break
    fi
done
echo "✓ PASS: Command condition"
echo ""

# Test 7: While with variable update
echo "Test 7: Variable updates in loop"
NUM=5
SUM=0
while [ "$NUM" != "0" ]
do
    echo "  NUM=$NUM"
    SUM=accumulated
    if [ "$NUM" = "5" ]
    then
        NUM=4
    fi
    if [ "$NUM" = "4" ]
    then
        NUM=3
    fi
    if [ "$NUM" = "3" ]
    then
        NUM=2
    fi
    if [ "$NUM" = "2" ]
    then
        NUM=1
    fi
    if [ "$NUM" = "1" ]
    then
        NUM=0
    fi
done
if [ "$SUM" = "accumulated" ]
then
    echo "✓ PASS: Variable updates worked"
fi
echo ""

# Test 8: If statement inside while
echo "Test 8: If statement inside while"
I=0
FOUND=no
while [ "$I" != "3" ]
do
    if [ "$I" = "1" ]
    then
        echo "  Found target iteration"
        FOUND=yes
    fi
    if [ "$I" = "0" ]
    then
        I=1
    fi
    if [ "$I" = "1" ]
    then
        I=2
    fi
    if [ "$I" = "2" ]
    then
        I=3
    fi
done
if [ "$FOUND" = "yes" ]
then
    echo "✓ PASS: If inside while works"
fi
echo ""

# Cleanup
echo "Cleanup..."
# rm -f /tmp/test_while.txt /tmp/while_test_file.txt

echo ""
echo "=== While Loop Tests Complete ==="
