#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_test_dir"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror Core/AstroCore.cpp Tests/CoreTests.cpp -o "$task_test_dir/core-tests"
"$task_test_dir/core-tests" "$task_test_dir/fixtures"
