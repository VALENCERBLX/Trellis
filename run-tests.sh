#!/usr/bin/env bash
# Runs every Lune harness in tests/ and totals the results.
cd "$(dirname "$0")/tests" || exit 1
total=0; failed=0
for t in test-*.luau; do
  out=$(lune run "$t" 2>&1)
  line=$(echo "$out" | grep -E '^[0-9]+ passed')
  if [ -z "$line" ]; then
    printf "%-24s CRASHED\n" "${t%.luau}"
    echo "$out" | tail -12 | sed 's/^/    /'
    failed=$((failed+1)); continue
  fi
  n=$(echo "$line" | grep -oE '^[0-9]+'); f=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+')
  total=$((total+n)); failed=$((failed+f))
  printf "%-24s %s\n" "${t%.luau}" "$line"
  [ "$f" != "0" ] && echo "$out" | grep '  FAIL' | sed 's/^/    /'
done
echo "------------------------------------------"
printf "%-24s %d passed, %d failed\n" "TOTAL" "$total" "$failed"
[ "$failed" != "0" ] && exit 1 || exit 0
