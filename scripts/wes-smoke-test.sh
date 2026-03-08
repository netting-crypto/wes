#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
result_subdir="${WES_RESULTS_SUBDIR:-results}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
result_dir="$output_dir/$result_subdir"
log_dir="$output_dir/$logs_subdir"
smoke_dir="$result_dir/smoke-test"
install_smoke="${WES_INSTALL_SMOKE:-1}"
conda_env_prefix="${WES_CONDA_ENV_PREFIX:-$smoke_dir/conda-smoke-env}"
conda_channels="${WES_CONDA_CHANNELS:-conda-forge bioconda}"
conda_packages="${WES_CONDA_PACKAGES:-bwa bcftools gatk4 fastqc}"

mkdir -p "$smoke_dir" "$log_dir"

log_file="$log_dir/smoke-test.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES smoke test =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
echo "project_dir=$project_dir"
echo "output_dir=$output_dir"

echo
echo "== Basic environment =="
echo "PATH=$PATH"
echo "SHELL=${SHELL:-}"
echo "USER=${USER:-}"
echo "HOME=${HOME:-}"
env | sort | grep -E '^(CI_|SLURM_|WES_|OUTPUT_DIR|PATH=)' || true

echo
echo "== Network probes =="
for url in \
  "https://repo.anaconda.com" \
  "https://conda.anaconda.org/bioconda" \
  "https://micro.mamba.pm" \
  "https://github.com"
do
  echo "-- curl -I $url"
  if command -v curl >/dev/null 2>&1; then
    curl -I --max-time 15 "$url" | head -n 5 || true
  elif command -v wget >/dev/null 2>&1; then
    wget -S --spider --timeout=15 "$url" 2>&1 | head -n 5 || true
  else
    echo "Neither curl nor wget is available"
  fi
done

echo
echo "== Command probes =="
for cmd in bash python python3 java conda mamba micromamba samtools bcftools bwa bwa-mem2 gatk fastqc fastp vep bgzip tabix sbatch squeue; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[FOUND] $cmd -> $(command -v "$cmd")"
  else
    echo "[MISSING] $cmd"
  fi
done

echo
echo "== Version probes =="
python3 --version 2>/dev/null || true
java -version 2>&1 | head -n 3 || true
conda --version 2>/dev/null || true
gatk --version 2>/dev/null || true
samtools --version 2>/dev/null | head -n 3 || true

echo
echo "== Writable probe =="
touch "$smoke_dir/write-test.txt"
echo "write_ok" > "$smoke_dir/write-test.txt"
ls -lh "$smoke_dir/write-test.txt"

echo
echo "== Sample probe =="
if [[ -n "${WES_FASTQ_DIR:-}" ]]; then
  echo "WES_FASTQ_DIR=$WES_FASTQ_DIR"
fi
if [[ -n "${WES_TEST_R1:-}" ]]; then
  if [[ -f "$WES_TEST_R1" ]]; then
    echo "[FOUND] WES_TEST_R1=$WES_TEST_R1"
    ls -lh "$WES_TEST_R1" || true
  else
    echo "[MISSING] WES_TEST_R1=$WES_TEST_R1"
  fi
fi
if [[ -n "${WES_TEST_R2:-}" ]]; then
  if [[ -f "$WES_TEST_R2" ]]; then
    echo "[FOUND] WES_TEST_R2=$WES_TEST_R2"
    ls -lh "$WES_TEST_R2" || true
  else
    echo "[MISSING] WES_TEST_R2=$WES_TEST_R2"
  fi
fi

echo
echo "== Conda install smoke test =="
echo "WES_INSTALL_SMOKE=$install_smoke"
if [[ "$install_smoke" == "1" ]]; then
  if command -v conda >/dev/null 2>&1; then
    echo "conda_env_prefix=$conda_env_prefix"
    echo "conda_channels=$conda_channels"
    echo "conda_packages=$conda_packages"
    rm -rf "$conda_env_prefix"
    channel_args=()
    for channel in $conda_channels; do
      channel_args+=(-c "$channel")
    done
    set +e
    conda create -y -p "$conda_env_prefix" "${channel_args[@]}" $conda_packages >"$log_dir/conda-create.stdout.log" 2>"$log_dir/conda-create.stderr.log"
    conda_status=$?
    set -e
    echo "conda_create_status=$conda_status"
    if [[ $conda_status -eq 0 ]]; then
      echo "[OK] conda create succeeded"
      "$conda_env_prefix/bin/python" --version 2>/dev/null || true
      "$conda_env_prefix/bin/bwa" 2>&1 | head -n 3 || true
      "$conda_env_prefix/bin/bcftools" --version 2>/dev/null | head -n 3 || true
      "$conda_env_prefix/bin/gatk" --version 2>/dev/null || true
      "$conda_env_prefix/bin/fastqc" --help 2>/dev/null | head -n 3 || true
    else
      echo "[FAIL] conda create failed"
      echo "--- conda stderr tail ---"
      tail -n 100 "$log_dir/conda-create.stderr.log" || true
    fi
  else
    echo "[SKIP] conda not found"
  fi
else
  echo "[SKIP] WES_INSTALL_SMOKE != 1"
fi

echo
echo "== Resource probe =="
for item in WES_REF_PATH WES_BED_PATH WES_KNOWN_SITES_VCF VEP_CACHE_DIR; do
  value="${!item:-}"
  if [[ -z "$value" ]]; then
    echo "[UNSET] $item"
  elif [[ -e "$value" ]]; then
    echo "[FOUND] $item=$value"
  else
    echo "[MISSING] $item=$value"
  fi
done

summary="$output_dir/smoke-summary.txt"
{
  echo "date=$(date -Iseconds)"
  echo "hostname=$(hostname)"
  echo "log=$log_file"
  echo "smoke_dir=$smoke_dir"
  echo "install_smoke=$install_smoke"
  echo "conda_env_prefix=$conda_env_prefix"
  echo "test_r1=${WES_TEST_R1:-}"
  echo "test_r2=${WES_TEST_R2:-}"
} > "$summary"

echo
echo "Smoke test finished."
echo "Summary: $summary"
