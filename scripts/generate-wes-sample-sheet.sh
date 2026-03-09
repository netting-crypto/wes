#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/generate-wes-sample-sheet.sh \
    --fastq-dir /path/to/fastq \
    --out config/wes/samples.generated.tsv

What this script does:
  - Recursively scans a FASTQ directory for paired-end files
  - Pairs R1/R2 files by common Illumina-style naming patterns
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

mapfile -t fastq_files < <(find "$FASTQ_DIR" -type f \( -name '*.fastq.gz' -o -name '*.fq.gz' \) | sort)

if [[ "${#fastq_files[@]}" -eq 0 ]]; then
  echo "No FASTQ files found under: $FASTQ_DIR" >&2
  exit 2
fi

to_r2_path() {
  local path="$1"
  case "$path" in
    *_R1_*) printf '%s\n' "${path/_R1_/_R2_}" ;;
    *_R1.*) printf '%s\n' "${path/_R1./_R2.}" ;;
    *.R1.*) printf '%s\n' "${path/.R1./.R2.}" ;;
    *_1.fastq.gz) printf '%s\n' "${path/_1.fastq.gz/_2.fastq.gz}" ;;
    *_1.fq.gz) printf '%s\n' "${path/_1.fq.gz/_2.fq.gz}" ;;
    *) return 1 ;;
  esac
}

infer_sample_id() {
  local base_name="$1"
  local sample_id="$base_name"
  sample_id="${sample_id%.fastq.gz}"
  sample_id="${sample_id%.fq.gz}"
  sample_id="${sample_id%%_R1_*}"
  sample_id="${sample_id%%_R2_*}"
  sample_id="${sample_id%%.R1.*}"
  sample_id="${sample_id%%.R2.*}"
  sample_id="${sample_id%%_1}"
  sample_id="${sample_id%%_2}"
  sample_id="$(printf '%s\n' "$sample_id" | sed -E 's/_S[0-9]+$//')"
  printf '%s\n' "$sample_id"
}

{
  printf 'sample_id\tfamily_id\trole\taffected\tfastq_r1\tfastq_r2\tbam_path\n'

  paired_count=0
  unmatched_count=0

  for r1 in "${fastq_files[@]}"; do
    base_name="$(basename "$r1")"
    r2="$(to_r2_path "$r1" || true)"
    [[ -n "$r2" ]] || continue
    if [[ ! -f "$r2" ]]; then
      echo "Skip unpaired FASTQ: $r1" >&2
      unmatched_count=$((unmatched_count + 1))
      continue
    fi

    sample_id="$(infer_sample_id "$base_name")"
    paired_count=$((paired_count + 1))

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
echo "paired_fastq_sets=$paired_count"
echo "unmatched_r1_candidates=$unmatched_count"
