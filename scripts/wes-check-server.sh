#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-config/wes/run.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Usage: bash scripts/wes-check-server.sh config/wes/run.env" >&2
  echo "Missing env file: $ENV_FILE" >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

declare -a KNOWN_SITES_TO_CHECK=()
for candidate in \
  "${WES_KNOWN_SITES_VCF:-}" \
  "${WES_DBSNP_PATH:-}" \
  "${WES_KNOWN_INDELS_PATH:-}" \
  "${WES_MILLS_PATH:-}" \
  "${WES_KNOWN_SITES_1:-}" \
  "${WES_KNOWN_SITES_2:-}" \
  "${WES_KNOWN_SITES_3:-}"
do
  [[ -n "$candidate" ]] || continue
  skip_candidate=0
  for seen in "${KNOWN_SITES_TO_CHECK[@]}"; do
    if [[ "$seen" == "$candidate" ]]; then
      skip_candidate=1
      break
    fi
  done
  if [[ "$skip_candidate" -eq 0 ]]; then
    KNOWN_SITES_TO_CHECK+=("$candidate")
  fi
done

print_ok() {
  printf '[OK] %s\n' "$1"
}

print_warn() {
  printf '[WARN] %s\n' "$1"
}

print_fail() {
  printf '[FAIL] %s\n' "$1"
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    print_ok "command found: $cmd -> $(command -v "$cmd")"
  else
    print_fail "command missing: $cmd"
  fi
}

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    print_ok "$label file exists: $path"
  else
    print_fail "$label file missing: $path"
  fi
}

check_dir() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    print_ok "$label directory exists: $path"
  else
    print_fail "$label directory missing: $path"
  fi
}

echo "== Basic commands =="
check_cmd bash
check_cmd samtools
check_cmd gatk
if command -v bwa-mem2 >/dev/null 2>&1; then
  print_ok "command found: bwa-mem2 -> $(command -v bwa-mem2)"
elif command -v bwa >/dev/null 2>&1; then
  print_ok "command found: bwa -> $(command -v bwa)"
else
  print_fail "need bwa-mem2 or bwa"
fi

if command -v fastqc >/dev/null 2>&1; then
  print_ok "optional command found: fastqc"
else
  print_warn "optional command missing: fastqc"
fi

if command -v fastp >/dev/null 2>&1; then
  print_ok "optional command found: fastp"
else
  print_warn "optional command missing: fastp"
fi

if command -v vep >/dev/null 2>&1; then
  print_ok "optional command found: vep"
else
  print_warn "optional command missing: vep"
fi

echo
echo "== Key files =="
check_file "$WES_REF_PATH" "reference"
check_file "$WES_BED_PATH" "target bed"
if [[ "${#KNOWN_SITES_TO_CHECK[@]}" -gt 0 ]]; then
  known_sites_idx=0
  for known_sites_vcf in "${KNOWN_SITES_TO_CHECK[@]}"; do
    known_sites_idx=$((known_sites_idx + 1))
    check_file "$known_sites_vcf" "known sites VCF $known_sites_idx"
  done
else
  print_warn "No known-sites VCF is set; first smoke test can still run with --skip-bqsr"
fi
check_dir "$WES_FASTQ_DIR" "FASTQ input"
check_file "$WES_SAMPLE_SHEET" "sample sheet"

echo
echo "== Reference sidecar files =="
if [[ -f "${WES_REF_PATH}.fai" ]]; then
  print_ok "reference index exists: ${WES_REF_PATH}.fai"
else
  print_fail "reference index missing: ${WES_REF_PATH}.fai"
fi

if [[ -f "${WES_REF_PATH%.*}.dict" ]]; then
  print_ok "reference dict exists: ${WES_REF_PATH%.*}.dict"
elif [[ -f "${WES_REF_PATH}.dict" ]]; then
  print_ok "reference dict exists: ${WES_REF_PATH}.dict"
else
  print_fail "reference dict missing near: $WES_REF_PATH"
fi

echo
echo "== Known-sites sidecar files =="
if [[ "${#KNOWN_SITES_TO_CHECK[@]}" -gt 0 ]]; then
  known_sites_idx=0
  for known_sites_vcf in "${KNOWN_SITES_TO_CHECK[@]}"; do
    known_sites_idx=$((known_sites_idx + 1))
    if [[ -f "${known_sites_vcf}.tbi" ]]; then
      print_ok "known sites VCF $known_sites_idx index exists: ${known_sites_vcf}.tbi"
    elif [[ -f "${known_sites_vcf}.idx" ]]; then
      print_ok "known sites VCF $known_sites_idx index exists: ${known_sites_vcf}.idx"
    else
      print_fail "known sites VCF $known_sites_idx index missing near: $known_sites_vcf"
    fi
  done
else
  print_warn "No known-sites index checks were run"
fi

echo
echo "== FASTQ preview =="
find "$WES_FASTQ_DIR" -maxdepth 2 -type f \( -name "*.fastq.gz" -o -name "*.fq.gz" \) | sort | head -n 20 || true

echo
echo "== Suggested smoke-test command =="
cat <<EOF
bash pipelines/wes-germline.sh \\
  --sample-sheet "$WES_SAMPLE_SHEET" \\
  --out "$OUTPUT_DIR/$WES_RESULTS_SUBDIR/smoke-test" \\
  --ref "$WES_REF_PATH" \\
  --bed "$WES_BED_PATH" \\
  --sample "<pick-one-sample-id>" \\
  --threads "${SLURM_CPUS_PER_TASK:-8}" \\
  $( for known_sites_vcf in "${KNOWN_SITES_TO_CHECK[@]}"; do printf -- '--known-sites "%s" \\\n  ' "$known_sites_vcf"; done )--skip-fastqc
EOF
