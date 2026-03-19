#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wes-inspect-family-call.sh \
    --vcf /path/to/joint.filtered.vcf.gz \
    --region X:38146170-38146210 \
    --expect-chrom X \
    --expect-pos 38146189 \
    --expect-ref C \
    --expect-alt CTCTCCATT \
    --output-prefix output/wes/company-compare-family22-rpgr

This is a read-only inspection helper. It does not modify the VCF.
It exports:
  - sample list
  - all calls in the requested region
  - exact-match rows for the expected REF/ALT
  - a short markdown-style summary in plain text
EOF
}

VCF_PATH=""
REGION=""
EXPECT_CHROM=""
EXPECT_POS=""
EXPECT_REF=""
EXPECT_ALT=""
OUTPUT_PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vcf) VCF_PATH="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --expect-chrom) EXPECT_CHROM="$2"; shift 2 ;;
    --expect-pos) EXPECT_POS="$2"; shift 2 ;;
    --expect-ref) EXPECT_REF="$2"; shift 2 ;;
    --expect-alt) EXPECT_ALT="$2"; shift 2 ;;
    --output-prefix) OUTPUT_PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing file: $path" >&2; exit 2; }
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 2; }
}

if [[ -z "$VCF_PATH" || -z "$REGION" || -z "$EXPECT_CHROM" || -z "$EXPECT_POS" || -z "$EXPECT_REF" || -z "$EXPECT_ALT" || -z "$OUTPUT_PREFIX" ]]; then
  usage
  exit 2
fi

require_file "$VCF_PATH"
require_cmd bcftools
require_cmd awk
require_cmd sed

if [[ ! -f "${VCF_PATH}.tbi" && ! -f "${VCF_PATH}.csi" ]]; then
  echo "Missing VCF index next to: $VCF_PATH" >&2
  exit 2
fi

output_dir="$(dirname "$OUTPUT_PREFIX")"
mkdir -p "$output_dir"

samples_path="${OUTPUT_PREFIX}-samples.txt"
region_path="${OUTPUT_PREFIX}-region.txt"
exact_path="${OUTPUT_PREFIX}-exact.txt"
summary_path="${OUTPUT_PREFIX}-summary.txt"

bcftools query -l "$VCF_PATH" > "$samples_path"

tmp_body="$(mktemp)"
tmp_exact="$(mktemp)"
trap 'rm -f "$tmp_body" "$tmp_exact"' EXIT

bcftools query \
  -r "$REGION" \
  -f '%CHROM\t%POS\t%REF\t%ALT\t%FILTER[\t%GT]\n' \
  "$VCF_PATH" > "$tmp_body"

{
  printf 'CHROM\tPOS\tREF\tALT\tFILTER'
  while IFS= read -r sample_name; do
    printf '\t%s' "$sample_name"
  done < "$samples_path"
  printf '\n'
  cat "$tmp_body"
} > "$region_path"

awk -F'\t' \
  -v expect_chrom="$EXPECT_CHROM" \
  -v expect_pos="$EXPECT_POS" \
  -v expect_ref="$EXPECT_REF" \
  -v expect_alt="$EXPECT_ALT" \
  'NR == 1 || ($1 == expect_chrom && $2 == expect_pos && $3 == expect_ref && $4 == expect_alt)' \
  "$region_path" > "$exact_path"

region_count=0
if [[ -s "$tmp_body" ]]; then
  region_count="$(wc -l < "$tmp_body" | tr -d '[:space:]')"
fi

exact_count=0
if [[ -s "$exact_path" ]]; then
  exact_count="$(tail -n +2 "$exact_path" | wc -l | tr -d '[:space:]')"
fi

{
  echo "# WES Company Call Inspection"
  echo
  echo "- vcf: $VCF_PATH"
  echo "- region: $REGION"
  echo "- expected: ${EXPECT_CHROM}:${EXPECT_POS} ${EXPECT_REF}>${EXPECT_ALT}"
  echo "- sample_count: $(wc -l < "$samples_path" | tr -d '[:space:]')"
  echo "- region_record_count: $region_count"
  echo "- exact_match_count: $exact_count"
  echo
  echo "## Samples"
  sed 's/^/- /' "$samples_path"
  echo
  echo "## Interpretation"
  if [[ "$exact_count" -gt 0 ]]; then
    echo "- Exact chrom/pos/ref/alt match found in our final joint.filtered.vcf.gz."
    echo "- Check ${exact_path} for genotypes in sample order."
  else
    echo "- Exact chrom/pos/ref/alt match was not found in the queried region."
    echo "- Check ${region_path} to inspect nearby calls and possible alternate representation."
  fi
} > "$summary_path"

echo "Inspection summary: $summary_path"
echo "Region table: $region_path"
echo "Exact-match table: $exact_path"
echo "Sample list: $samples_path"
