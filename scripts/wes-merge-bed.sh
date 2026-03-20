#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wes-merge-bed.sh \
    --base-bed /path/to/base.bed \
    --extra-bed /path/to/extra.bed \
    --output-bed /path/to/merged.bed

Merges two BED files into one sorted, non-overlapping BED.
EOF
}

BASE_BED=""
EXTRA_BED=""
OUTPUT_BED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-bed) BASE_BED="$2"; shift 2 ;;
    --extra-bed) EXTRA_BED="$2"; shift 2 ;;
    --output-bed) OUTPUT_BED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -f "$BASE_BED" ]] || { echo "Missing file: $BASE_BED" >&2; exit 2; }
[[ -f "$EXTRA_BED" ]] || { echo "Missing file: $EXTRA_BED" >&2; exit 2; }
[[ -n "$OUTPUT_BED" ]] || { usage; exit 2; }

output_dir="$(dirname "$OUTPUT_BED")"
mkdir -p "$output_dir"

tmp_sorted="$(mktemp)"
trap 'rm -f "$tmp_sorted"' EXIT

awk '
  BEGIN { OFS="\t" }
  $0 ~ /^#/ { next }
  NF < 3 { next }
  { print $1, $2, $3 }
' "$BASE_BED" "$EXTRA_BED" \
  | sort -k1,1 -k2,2n -k3,3n > "$tmp_sorted"

awk '
  BEGIN { OFS="\t" }
  NR == 1 {
    chr = $1
    start = $2
    end = $3
    next
  }
  {
    if ($1 == chr && $2 <= end) {
      if ($3 > end) {
        end = $3
      }
    } else {
      print chr, start, end
      chr = $1
      start = $2
      end = $3
    }
  }
  END {
    if (NR > 0) {
      print chr, start, end
    }
  }
' "$tmp_sorted" > "$OUTPUT_BED"

echo "$OUTPUT_BED"
