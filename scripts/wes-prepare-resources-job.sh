#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
log_dir="$output_dir/$logs_subdir"
resource_base="${WES_RESOURCE_BASE:-/home/zhangmeigroup/luoxin23/resources/hg38}"
conda_env_prefix="${WES_CONDA_ENV_PREFIX:-${TMPDIR:-/tmp}/wes-resource-conda-${SLURM_JOB_ID:-$$}}"
conda_channels="${WES_CONDA_CHANNELS:-conda-forge bioconda}"
conda_packages="${WES_RESOURCE_CONDA_PACKAGES:-samtools gatk4 htslib}"
allow_missing_known_sites="${WES_ALLOW_MISSING_KNOWN_SITES:-0}"

mkdir -p "$output_dir" "$log_dir"

log_file="$log_dir/prepare-resources.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES resource preparation =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
echo "project_dir=$project_dir"
echo "output_dir=$output_dir"
echo "resource_base=$resource_base"

echo
echo "== Environment =="
env | sort | grep -E '^(CI_|SLURM_|WES_|OUTPUT_DIR|PATH=)' || true

if ! command -v conda >/dev/null 2>&1; then
  echo "conda is required for resource preparation on the compute node" >&2
  exit 2
fi

rm -rf "$conda_env_prefix"
channel_args=()
for channel in $conda_channels; do
  channel_args+=(-c "$channel")
done

echo
echo "== Creating temporary conda env =="
echo "conda_env_prefix=$conda_env_prefix"
echo "conda_channels=$conda_channels"
echo "conda_packages=$conda_packages"
set +e
conda create -y -p "$conda_env_prefix" "${channel_args[@]}" $conda_packages >"$log_dir/resource-conda.stdout.log" 2>"$log_dir/resource-conda.stderr.log"
conda_status=$?
set -e
echo "conda_create_status=$conda_status"
if [[ $conda_status -ne 0 ]]; then
  echo "[FAIL] conda create failed"
  tail -n 100 "$log_dir/resource-conda.stderr.log" || true
  exit "$conda_status"
fi

echo "[OK] conda create succeeded"
"$conda_env_prefix/bin/python" --version 2>/dev/null || true
"$conda_env_prefix/bin/samtools" --version 2>/dev/null | head -n 3 || true
"$conda_env_prefix/bin/gatk" --version 2>/dev/null || true
"$conda_env_prefix/bin/tabix" --version 2>/dev/null | head -n 2 || true

export PATH="$conda_env_prefix/bin:$PATH"

prepare_args=(
  --base-dir "$resource_base"
  --ref-url "${REF_URL:-}"
  --dbsnp-url "${DBSNP_URL:-}"
  --known-indels-url "${KNOWN_INDELS_URL:-}"
  --mills-url "${MILLS_URL:-}"
)

if [[ -n "${BED_URL:-}" ]]; then
  prepare_args+=(--bed-url "$BED_URL")
fi
if [[ -n "${GENCODE_GTF_URL:-}" ]]; then
  prepare_args+=(--gencode-gtf-url "$GENCODE_GTF_URL")
fi
if [[ -n "${WES_BED_PADDING_BP:-}" ]]; then
  prepare_args+=(--bed-padding-bp "$WES_BED_PADDING_BP")
fi
if [[ "$allow_missing_known_sites" == "1" ]]; then
  prepare_args+=(--allow-missing-known-sites)
fi
if [[ "${WES_SKIP_VEP:-1}" == "1" ]]; then
  prepare_args+=(--skip-vep)
elif [[ -n "${VEP_CACHE_URL:-}" ]]; then
  prepare_args+=(--vep-cache-url "$VEP_CACHE_URL")
fi

echo
echo "== Running prepare-wes-resources.sh =="
printf 'prepare_args=%q ' "${prepare_args[@]}"
echo
bash "$project_dir/scripts/prepare-wes-resources.sh" "${prepare_args[@]}"

manifest="$resource_base/resources.manifest.txt"
summary="$output_dir/prepare-resources-summary.txt"
{
  echo "date=$(date -Iseconds)"
  echo "hostname=$(hostname)"
  echo "log=$log_file"
  echo "resource_base=$resource_base"
  echo "manifest=$manifest"
  echo "allow_missing_known_sites=$allow_missing_known_sites"
  echo "ref=$resource_base/reference/Homo_sapiens_assembly38.fasta"
  echo "dbsnp=$resource_base/known-sites/Homo_sapiens_assembly38.dbsnp138.vcf"
  echo "known_indels=$resource_base/known-sites/Homo_sapiens_assembly38.known_indels.vcf.gz"
  echo "mills=$resource_base/known-sites/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"
  echo "bed=$resource_base/targets/exome_targets.bed"
  echo "vep_cache=$resource_base/vep/cache"
} > "$summary"

echo
echo "== Resource probe =="
for item in \
  "$resource_base/reference/Homo_sapiens_assembly38.fasta" \
  "$resource_base/reference/Homo_sapiens_assembly38.fasta.fai" \
  "$resource_base/reference/Homo_sapiens_assembly38.dict" \
  "$resource_base/known-sites/Homo_sapiens_assembly38.dbsnp138.vcf" \
  "$resource_base/known-sites/Homo_sapiens_assembly38.known_indels.vcf.gz" \
  "$resource_base/known-sites/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"
do
  if [[ -e "$item" ]]; then
    echo "[FOUND] $item"
    ls -lh "$item" || true
  else
    echo "[MISSING] $item"
  fi
done

if [[ -d "$conda_env_prefix" ]]; then
  echo "Cleaning temporary conda env: $conda_env_prefix"
  rm -rf "$conda_env_prefix"
fi

echo
echo "Resource preparation finished."
echo "Summary: $summary"
