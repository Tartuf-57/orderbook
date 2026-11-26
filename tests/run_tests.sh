#!/usr/bin/env bash
# OrderBook scenario tests.
#
#   bash tests/run_tests.sh              run every scenario
#   bash tests/run_tests.sh partial      run scenarios whose name contains "partial"
#
# WARNING: every scenario starts with "reset", which wipes the database
# back to the demo data. Run this from the project folder (the one that
# contains orderbook.conf) after building the program.

cd "$(dirname "$0")/.." || exit 1
BIN="${BIN:-./build/orderbook}"
FILE="${SCEN_FILE:-tests/scenarios.txt}"
FILTER="${1:-}"

if [[ ! -x "$BIN" ]]; then
    echo "Program not found: $BIN  (build it first)"
    exit 1
fi

pass=0
fail=0

run_scenario() {
    local name="$1" input="$2" expect="$3"
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then return; fi

    # An input may hold several program sessions separated by ---SESSION---
    local sessions=() buf="" line
    while IFS= read -r line; do
        if [[ "$line" == "---SESSION---" ]]; then
            sessions+=("$buf"); buf=""
        else
            buf+="$line"$'\n'
        fi
    done <<< "$input"
    sessions+=("$buf")

    # Run each session; squeeze repeated spaces so table padding does not matter.
    local outputs=() all="" out
    for s in "${sessions[@]}"; do
        out=$(printf '%s' "$s" | "$BIN" 2>&1 | tr -s ' ')
        outputs+=("$out")
        all+="$out"$'\n'
    done

    local ok=1 i
    for i in "${!outputs[@]}"; do
        if ! grep -qF "Goodbye." <<< "${outputs[$i]}"; then
            echo "    program did not exit cleanly in session $((i + 1))"
            ok=0
        fi
    done

    # Expectation lines:   text        must appear somewhere
    #                      @2 text     must appear in session 2
    #                      !text       must NOT appear anywhere
    #                      !@2 text    must NOT appear in session 2
    local want neg hay found re='^@([0-9]+) (.*)$'
    while IFS= read -r want; do
        [[ -z "$want" ]] && continue
        neg=0
        hay="$all"
        if [[ "$want" == !* ]]; then neg=1; want="${want:1}"; fi
        if [[ "$want" =~ $re ]]; then
            hay="${outputs[$((BASH_REMATCH[1] - 1))]}"
            want="${BASH_REMATCH[2]}"
        fi
        if grep -qF -- "$want" <<< "$hay"; then found=1; else found=0; fi

        if (( neg == 1 && found == 1 )); then
            echo "    should NOT contain: $want"; ok=0
        elif (( neg == 0 && found == 0 )); then
            echo "    missing: $want"; ok=0
        fi
    done <<< "$expect"

    if (( ok == 1 )); then
        echo "PASS  $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name"; fail=$((fail + 1))
    fi
}

name="" mode="" input="" expect=""
flush() {
    if [[ -n "$name" ]]; then run_scenario "$name" "$input" "$expect"; fi
    input=""; expect=""
}

while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        "=== "*)      flush; name="${line#=== }"; mode="" ;;
        "--- input")  mode=input ;;
        "--- expect") mode=expect ;;
        "#"*|"")      ;;                                   # comments and blank lines
        *)  if   [[ "$mode" == input  ]]; then input+="$line"$'\n'
            elif [[ "$mode" == expect ]]; then expect+="$line"$'\n'
            fi ;;
    esac
done < "$FILE"
flush

echo
echo "Passed: $pass   Failed: $fail"
(( fail == 0 ))
