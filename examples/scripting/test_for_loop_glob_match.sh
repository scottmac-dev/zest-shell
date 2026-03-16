echo "TEST 1"
echo "finding all *.zig files in src/lib/..."
for file in ./src/lib/*.zig
do
    echo "Processing $file"
done
echo ""

echo "TEST 2"
echo "finding all *.sh files in scripts/benchmarks/..."
for script in ./scripts/benchmarks/*.sh
do
    echo "Running $script"
done
echo ""

echo "TEST 3"
echo "finding all test_for_*.sh files in scripts/tests/..."
for file in ./scripts/tests/test_for_*.sh
do
    if [ -f "$file" ] 
    then
         echo "Found: $file"
    fi
done
echo ""
