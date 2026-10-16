#!/usr/bin/env bash
# End-to-end tests for run.sh: each case runs the real image-tools container on a
# generated PNG, the way the action does on a runner, and checks the outputs,
# the job summary and the exit status. Needs Docker.
#
#   IMAGE_VERSION=0.2.0 test/run.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_VERSION="${IMAGE_VERSION:?set IMAGE_VERSION to the image-tools tag under test}"
IMAGE="ghcr.io/nucliweb/image-tools:${IMAGE_VERSION}"

FAILURES=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A fresh workspace with one generated image, and the files GitHub provides.
new_workspace() {
  WS="$(mktemp -d)"
  mkdir -p "$WS/images"
  docker run --rm -u "$(id -u):$(id -g)" -v "$WS:/work" -w /work --entrypoint magick "$IMAGE" \
    -size 128x96 gradient:navy-orange images/sample.png
  : > "$WS/output"
  : > "$WS/summary"
}

# Run the action script in the workspace with the given INPUT_* variables.
run_action() {
  (
    cd "$WS" &&
      env INPUT_IMAGES="images" INPUT_TARGET="85" INPUT_CODECS="jxl,webp" INPUT_HTML="true" \
        INPUT_TOLERANCE="0.02" INPUT_QUALITY_TOLERANCE="0.5" INPUT_FAIL_ON_REGRESSION="true" \
        INPUT_OUTPUT_DIR="codec-comparison" INPUT_IMAGE_VERSION="$IMAGE_VERSION" \
        GITHUB_WORKSPACE="$WS" GITHUB_OUTPUT="$WS/output" GITHUB_STEP_SUMMARY="$WS/summary" \
        "$@" bash "$ROOT/run.sh"
  ) > "$WS/log" 2>&1
}

output() { grep "^$1=" "$WS/output" | tail -1 | cut -d= -f2-; }

echo "single target"
new_workspace
run_action
check "exits 0" "[ $? -eq 0 ]"
check "writes the CSV, one row per codec" "[ \$(wc -l < '$WS/codec-comparison/results.csv') -eq 3 ]"
check "writes the HTML report" "[ -s '$WS/codec-comparison/report.html' ]"
check "outputs the CSV path" "[ \"\$(output csv)\" = codec-comparison/results.csv ]"
check "outputs the report path" "[ \"\$(output report)\" = codec-comparison/report.html ]"
check "puts the table in the job summary" "grep -q 'Codec comparison' '$WS/summary'"
check "reports no regression without a baseline" "[ \"\$(output regressed)\" = false ]"
SINGLE_WS="$WS"

echo "rate-distortion"
new_workspace
run_action INPUT_RD="75,85"
check "exits 0" "[ $? -eq 0 ]"
check "writes one CSV row per codec and target" "[ \$(wc -l < '$WS/codec-comparison/results.csv') -eq 5 ]"
check "skips the HTML report" "[ ! -e '$WS/codec-comparison/report.html' ] && [ -z \"\$(output report)\" ]"
check "puts the RD table in the job summary" "grep -q 'Rate–distortion' '$WS/summary'"

echo "opt-in variant"
new_workspace
run_action INPUT_CODECS="webp,webp-sharp" INPUT_HTML="false"
check "exits 0" "[ $? -eq 0 ]"
check "measures the variant" "grep -q 'WebP sharp YUV' '$WS/codec-comparison/results.csv'"

echo "baseline gate, no regression"
WS="$SINGLE_WS"
docker run --rm -u "$(id -u):$(id -g)" -v "$WS:/work" -w /work --entrypoint node "$IMAGE" \
  /opt/image-tools/compare/bin/check-regression.js baseline.json codec-comparison/results.csv --update --target 85 > /dev/null
: > "$WS/output"
: > "$WS/summary"
run_action INPUT_BASELINE="baseline.json"
check "exits 0" "[ $? -eq 0 ]"
check "outputs regressed=false" "[ \"\$(output regressed)\" = false ]"
check "puts the check in the job summary" "grep -q 'OK: no size or quality regressions' '$WS/summary'"

echo "baseline gate, regression"
sed -E 's/"bytes": [0-9]+/"bytes": 10/' "$WS/baseline.json" > "$WS/smaller.json"
: > "$WS/output"
run_action INPUT_BASELINE="smaller.json"
check "fails the step" "[ $? -ne 0 ]"
check "outputs regressed=true" "[ \"\$(output regressed)\" = true ]"
: > "$WS/output"
run_action INPUT_BASELINE="smaller.json" INPUT_FAIL_ON_REGRESSION="false"
check "passes with fail-on-regression: false" "[ $? -eq 0 ]"
check "still outputs regressed=true" "[ \"\$(output regressed)\" = true ]"

echo "invalid combination"
run_action INPUT_RD="75,85" INPUT_BASELINE="baseline.json"
check "rejects rd with a baseline" "[ $? -ne 0 ] && grep -q 'baseline' '$WS/log'"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
