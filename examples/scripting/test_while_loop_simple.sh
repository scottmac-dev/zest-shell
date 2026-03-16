i=1
echo "TEST 1: SIMPLE COUNT ITERATION"
echo "Start: $i"

while [ $i -lt 5 ]
do
  echo "Loop: $i"
  i=$(expr $i + 1)
done


echo "End: $i"
echo "Done"
