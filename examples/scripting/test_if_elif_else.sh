#!/usr/bin/env bash

# Multiple commands in else

echo "Test 1: Simple if, elif, else"
if false
then
    echo "FAIL: shouldnt print"
elif false
then 
    echo "FAIL: shouldnt print"
else
    echo "PASS: else case wins"
fi

echo "Test 2: if, elif, else with with elif as pass case"
if false 
then
    echo "FAIL: shouldnt print"
elif true
then 
    echo "PASS: elif case wins"
else
    echo "FAIL: else shouldnt print"
fi

echo "Test 3: if, elif, else with with if as pass case"
if true
then
    echo "PASS: if case wins"
elif true
then 
    echo "FAIL: shouldnt print"
else
    echo "FAIL: else shouldnt print"
fi

echo "Test 4: 5 state elif with some inline ; then cases"
if false
then
    echo "FAIL: shouldnt print"
elif false; then 
    echo "FAIL: shouldnt print"
elif false; then
    echo "FAIL: else shouldnt print"
elif true 
then
    echo "PASS: elif number 3 wins"
else 
    echo "FAIL: else shouldnt print"
fi
