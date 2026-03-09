#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/generate-wes-sample-sheet.sh \
    --fastq-dir /path/to/fastq \
    --out config/wes/samples.generated.tsv

What this script does:
  - Scans a FASTQ directory for paired-end files
  - Pairs R1/R2 files by Illumina-style naming
  - Writes a sample sheet usable for `--stage preprocess`

Defaults used in the generated sample sheet:
  family_id = sample_id
  role = unknown
  affected = 0
  bam_path = empty
EOF
}

FASTQ_DIR=""
OUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fastq-dir) FASTQ_DIR="$2"; shift 2 ;;
    --out) OUT_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$FASTQ_DIR" || -z "$OUT_PATH" ]]; then
  usage
  exit 2
fi

[[ -d "$FASTQ_DIR" ]] || { echo "Missing FASTQ directory: $FASTQ_DIR" >&2; exit 2; }

mkdir -p "$(dirname "$OUT_PATH")"

shopt -s nullglob
declare -a r1_files=("$FASTQ_DIR"/*_R1_*.fastq.gz "$FASTQ_DIR"/*_R1_*.fq.gz)
shopt -u nullglob

if [[ "${#r1_files[@]}" -eq 0 ]]; then
  echo "No R1 FASTQ files found under: $FASTQ_DIR" >&2
  exit 2
fi

{
  printf 'sample_id\tfamily_id\trole\taffected\tfastq_r1\tfastq_r2\tbam_path\n'

  for r1 in "${r1_files[@]}"; do
    base_name="$(basename "$r1")"
    r2="${r1/_R1_/_R2_}"
    if [[ ! -f "$r2" ]]; then
      echo "Skip unpaired FASTQ: $r1" >&2
      continue
    fi

    sample_id="$base_name"
    sample_id="${sample_id%%_R1_*}"
    sample_id="$(printf '%s\n' "$sample_id" | sed -E 's/_S[0-9]+$//')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sample_id" \
      "$sample_id" \
      "unknown" \
      "0" \
      "$r1" \
      "$r2" \
      ""
  done
} > "$OUT_PATH"

echo "Generated sample sheet: $OUT_PATH"
