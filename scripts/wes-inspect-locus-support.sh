#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wes-inspect-locus-support.sh \
    --sample-sheet config/wes/samples.family22.tsv \
    --bed /path/to/exome_targets.bed \
    --region chrX:38146170-38146210 \
    --position chrX:38146189 \
    --output-prefix output/wes/family22-rpgr-support

Exports:
  - <prefix>-bed-overlap.txt
  - <prefix>-depth.txt
  - <prefix>-flagstat.txt
  - <prefix>-mpileup.txt
  - <prefix>-summary.txt

The script is read-only. It inspects coverage/support around a locus for all BAMs
listed in the sample sheet.
EOF
}

SAMPLE_SHEET=""
BED_PATH=""
REGION=""
POSITION=""
OUTPUT_PREFIX=""
REF_PATH="${WES_REF_PATH:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-sheet) SAMPLE_SHEET="$2"; shift 2 ;;
    --bed) BED_PATH="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --position) POSITION="$2"; shift 2 ;;
    --output-prefix) OUTPUT_PREFIX="$2"; shift 2 ;;
    --ref) REF_PATH="$2"; shift 2 ;;
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

if [[ -z "$SAMPLE_SHEET" || -z "$BED_PATH" || -z "$REGION" || -z "$POSITION" || -z "$OUTPUT_PREFIX" ]]; then
  usage
  exit 2
fi

require_file "$SAMPLE_SHEET"
require_file "$BED_PATH"
require_cmd samtools
require_cmd awk

output_dir="$(dirname "$OUTPUT_PREFIX")"
mkdir -p "$output_dir"

bed_path="${OUTPUT_PREFIX}-bed-overlap.txt"
depth_path="${OUTPUT_PREFIX}-depth.txt"
flagstat_path="${OUTPUT_PREFIX}-flagstat.txt"
mpileup_path="${OUTPUT_PREFIX}-mpileup.txt"
summary_path="${OUTPUT_PREFIX}-summary.txt"

region_chrom="${REGION%%:*}"
region_start_end="${REGION#*:}"
region_start="${region_start_end%-*}"
region_end="${region_start_end#*-}"
position_chrom="${POSITION%%:*}"
position_pos="${POSITION#*:}"

awk -v chrom="$position_chrom" -v pos="$position_pos" 'BEGIN{FS=OFS="\t"} $1==chrom && $2<=pos && $3>=pos { print }' "$BED_PATH" > "$bed_path"

{
  printf 'sample_id\tbam_path\tdepth_at_position\n'
  while IFS=$'\t' read -r sample_id family_id role affected fastq_r1 fastq_r2 bam_path; do
    [[ -n "${sample_id:-}" ]] || continue
    [[ "$sample_id" == "sample_id" ]] && continue
    require_file "$bam_path"
    depth_value="$(samtools depth -r "$POSITION" "$bam_path" | awk 'NR==1{print $3}')"
    if [[ -z "$depth_value" ]]; then
      depth_value="0"
    fi
    printf '%s\t%s\t%s\n' "$sample_id" "$bam_path" "$depth_value"
  done < "$SAMPLE_SHEET"
} > "$depth_path"

{
  while IFS=$'\t' read -r sample_id family_id role affected fastq_r1 fastq_r2 bam_path; do
    [[ -n "${sample_id:-}" ]] || continue
    [[ "$sample_id" == "sample_id" ]] && continue
    echo "## $sample_id"
    samtools flagstat "$bam_path" | sed 's/^/  /'
    echo
  done < "$SAMPLE_SHEET"
} > "$flagstat_path"

{
  while IFS=$'\t' read -r sample_id family_id role affected fastq_r1 fastq_r2 bam_path; do
    [[ -n "${sample_id:-}" ]] || continue
    [[ "$sample_id" == "sample_id" ]] && continue
    echo "## $sample_id"
    if [[ -n "$REF_PATH" && -f "$REF_PATH" ]]; then
      samtools mpileup -r "$REGION" -f "$REF_PATH" "$bam_path"
    else
      samtools mpileup -r "$REGION" "$bam_path"
    fi
    echo
  done < "$SAMPLE_SHEET"
} > "$mpileup_path"

bed_hit_count="$(wc -l < "$bed_path" | tr -d '[:space:]')"
{
  echo "# Locus support inspection"
  echo
  echo "- sample_sheet: $SAMPLE_SHEET"
  echo "- bed: $BED_PATH"
  echo "- region: $REGION"
  echo "- position: $POSITION"
  echo "- bed_overlap_count: $bed_hit_count"
  if [[ "$bed_hit_count" -gt 0 ]]; then
    echo "- interpretation: target BED contains the locus according to the current coordinate naming."
  else
    echo "- interpretation: target BED did not show any interval covering the requested locus."
  fi
  echo "- files: $bed_path, $depth_path, $flagstat_path, $mpileup_path"
} > "$summary_path"

echo "Summary: $summary_path"
echo "BED overlap: $bed_path"
echo "Depth table: $depth_path"
echo "Flagstat: $flagstat_path"
echo "Mpileup: $mpileup_path"
