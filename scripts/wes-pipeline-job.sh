#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
log_dir="$output_dir/$logs_subdir"
use_conda_pipeline="${WES_PIPELINE_USE_CONDA:-1}"
conda_env_prefix="${WES_PIPELINE_CONDA_ENV_PREFIX:-${TMPDIR:-/tmp}/wes-pipeline-conda-${SLURM_JOB_ID:-$$}}"
conda_channels="${WES_CONDA_CHANNELS:-conda-forge bioconda}"
conda_packages="${WES_PIPELINE_CONDA_PACKAGES:-bwa samtools bcftools gatk4 htslib fastp fastqc}"

mkdir -p "$output_dir" "$log_dir"

log_file="$log_dir/pipeline-wrapper.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES pipeline wrapper =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "project_dir=$project_dir"
echo "output_dir=$output_dir"
echo "use_conda_pipeline=$use_conda_pipeline"

if [[ "$use_conda_pipeline" == "1" ]]; then
  if ! command -v conda >/dev/null 2>&1; then
    echo "conda is required when WES_PIPELINE_USE_CONDA=1" >&2
    exit 2
  fi

  rm -rf "$conda_env_prefix"
  channel_args=()
  for channel in $conda_channels; do
    channel_args+=(-c "$channel")
  done

  echo "Creating temporary pipeline conda env: $conda_env_prefix"
  echo "conda_channels=$conda_channels"
  echo "conda_packages=$conda_packages"

  set +e
  conda create -y -p "$conda_env_prefix" "${channel_args[@]}" $conda_packages >"$log_dir/pipeline-conda.stdout.log" 2>"$log_dir/pipeline-conda.stderr.log"
  conda_status=$?
  set -e
  echo "conda_create_status=$conda_status"
  if [[ $conda_status -ne 0 ]]; then
    echo "[FAIL] pipeline conda create failed"
    tail -n 100 "$log_dir/pipeline-conda.stderr.log" || true
    exit "$conda_status"
  fi

  export PATH="$conda_env_prefix/bin:$PATH"
fi

echo "Running pipeline command"
echo "WES_PIPELINE_CMD=${WES_PIPELINE_CMD:?WES_PIPELINE_CMD is required when WES_MODE=pipeline}"
bash -lc "$WES_PIPELINE_CMD"

if [[ "$use_conda_pipeline" == "1" && -d "$conda_env_prefix" ]]; then
  echo "Cleaning temporary pipeline conda env: $conda_env_prefix"
  rm -rf "$conda_env_prefix"
fi

echo "Pipeline wrapper finished."
