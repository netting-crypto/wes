#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wes-export-family-variants.sh \
    --vcf /path/to/joint.filtered.vcf.gz \
    --output-prefix output/wes/family22-filtered \
    [--proband-column 6]

Exports:
  - <prefix>-samples.txt
  - <prefix>-all.txt
  - <prefix>-proband-nonref.txt
  - <prefix>-summary.txt

The default proband column assumes table layout:
  CHROM POS REF ALT FILTER SAMPLE1 SAMPLE2 ...
so the first sample genotype column is 6.
EOF
}

VCF_PATH=""
OUTPUT_PREFIX=""
PROBAND_COLUMN="6"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vcf) VCF_PATH="$2"; shift 2 ;;
    --output-prefix) OUTPUT_PREFIX="$2"; shift 2 ;;
    --proband-column) PROBAND_COLUMN="$2"; shift 2 ;;
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

if [[ -z "$VCF_PATH" || -z "$OUTPUT_PREFIX" ]]; then
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
all_path="${OUTPUT_PREFIX}-all.txt"
proband_path="${OUTPUT_PREFIX}-proband-nonref.txt"
summary_path="${OUTPUT_PREFIX}-summary.txt"

bcftools query -l "$VCF_PATH" > "$samples_path"

{
  printf 'CHROM\tPOS\tREF\tALT\tFILTER'
  while IFS= read -r sample_name; do
    printf '\t%s' "$sample_name"
  done < "$samples_path"
  printf '\n'
  bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%FILTER[\t%GT]\n' "$VCF_PATH"
} > "$all_path"

awk -F'\t' -v col="$PROBAND_COLUMN" '
  NR == 1 { print; next }
  $col != "0/0" && $col != "./." && $col != "." { print }
' "$all_path" > "$proband_path"

total_count="$(tail -n +2 "$all_path" | wc -l | tr -d '[:space:]')"
proband_count="$(tail -n +2 "$proband_path" | wc -l | tr -d '[:space:]')"
sample_count="$(wc -l < "$samples_path" | tr -d '[:space:]')"

{
  echo "# Family variant export"
  echo
  echo "- vcf: $VCF_PATH"
  echo "- sample_count: $sample_count"
  echo "- total_records: $total_count"
  echo "- proband_nonref_records: $proband_count"
  echo "- proband_column: $PROBAND_COLUMN"
  echo "- sample_order: $(paste -sd ',' "$samples_path")"
  echo "- all_table: $all_path"
  echo "- proband_nonref_table: $proband_path"
} > "$summary_path"

echo "Variant summary: $summary_path"
echo "All variants: $all_path"
echo "Proband non-ref variants: $proband_path"
echo "Sample list: $samples_path"
