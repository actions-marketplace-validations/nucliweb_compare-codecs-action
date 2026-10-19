#!/usr/bin/env bash
# Runs compare-codecs (and optionally the regression gate) inside the pinned
# image-tools container. Inputs arrive as INPUT_* variables from action.yml.
set -euo pipefail

IMAGE="ghcr.io/nucliweb/image-tools:${INPUT_IMAGE_VERSION}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
OUT="${INPUT_OUTPUT_DIR}"
RD="${INPUT_RD:-}"
BASELINE="${INPUT_BASELINE:-}"

if [ -n "$RD" ] && [ -n "$BASELINE" ]; then
  echo "::error::The baseline gate checks a single target; it cannot be combined with rd."
  exit 1
fi

# Paths are relative to the workspace, which is mounted at /work in the container.
# Run as the runner's user so the files written stay writable by later steps.
in_image() {
  local entrypoint="$1"
  shift
  docker run --rm -u "$(id -u):$(id -g)" -v "$WORKSPACE:/work" -w /work \
    --entrypoint "$entrypoint" "$IMAGE" "$@"
}

# One image path or directory per line, so paths may contain spaces.
args=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] && args+=("$line")
done <<< "$INPUT_IMAGES"
if [ ${#args[@]} -eq 0 ]; then
  echo "::error::The images input is empty."
  exit 1
fi

if [ -n "$RD" ]; then
  args+=(--rd "$RD")
else
  args+=(--target "$INPUT_TARGET")
fi
[ -n "${INPUT_CODECS:-}" ] && args+=(--codecs "$INPUT_CODECS")
[ -n "${INPUT_EFFORT:-}" ] && args+=(--effort "$INPUT_EFFORT")

mkdir -p "$WORKSPACE/$OUT"
csv="$OUT/results.csv"
args+=(--csv "$csv")

# The report plots rate-distortion curves from image-tools 0.5.0; earlier images
# reject --html with --rd. Tags that are not a version (latest, sha-…) are recent.
rd_report_supported() {
  [[ "$INPUT_IMAGE_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
  [ "${BASH_REMATCH[1]}" -gt 0 ] || [ "${BASH_REMATCH[2]}" -ge 5 ]
}

report=""
if [ "${INPUT_HTML}" = "true" ]; then
  if [ -n "$RD" ] && ! rd_report_supported; then
    echo "::notice::The HTML report in rate-distortion mode needs image-tools 0.5.0 or later; skipping it."
  else
    report="$OUT/report.html"
    args+=(--html "$report")
    [ -n "${INPUT_HTML_MAX_DIM:-}" ] && args+=(--html-max-dim "$INPUT_HTML_MAX_DIM")
  fi
fi

in_image compare-codecs "${args[@]}" | tee "$WORKSPACE/$OUT/comparison.txt"
{
  echo "## Codec comparison"
  echo ""
  echo '```'
  cat "$WORKSPACE/$OUT/comparison.txt"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

regressed=false
if [ -n "$BASELINE" ]; then
  status=0
  in_image node /opt/image-tools/compare/bin/check-regression.js "$BASELINE" "$csv" \
    --target "$INPUT_TARGET" --tolerance "$INPUT_TOLERANCE" --quality-tolerance "$INPUT_QUALITY_TOLERANCE" \
    > "$WORKSPACE/$OUT/regression.txt" 2>&1 || status=$?
  cat "$WORKSPACE/$OUT/regression.txt"
  [ "$status" -ne 0 ] && regressed=true
  {
    echo ""
    echo "## Size and quality regression check"
    echo ""
    echo '```'
    cat "$WORKSPACE/$OUT/regression.txt"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

{
  echo "csv=$csv"
  echo "report=$report"
  echo "regressed=$regressed"
} >> "$GITHUB_OUTPUT"

if [ "$regressed" = true ] && [ "${INPUT_FAIL_ON_REGRESSION}" = "true" ]; then
  echo "::error::Size or quality regression against $BASELINE; see the job summary."
  exit 1
fi
