#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
log_dir="$output_dir/$logs_subdir"
sample_sheet="${WES_SAMPLE_SHEET:?WES_SAMPLE_SHEET is required}"
array_task_id="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
shared_env_prefix="${WES_PREPROCESS_CONDA_ENV_PREFIX:-$output_dir/shared-envs/preprocess-conda}"
use_conda_pipeline="${WES_PIPELINE_USE_CONDA:-1}"
conda_channels="${WES_CONDA_CHANNELS:-conda-forge bioconda}"
conda_packages="${WES_PREPROCESS_CONDA_PACKAGES:-bwa samtools bcftools gatk4 htslib fastp fastqc}"

mkdir -p "$output_dir" "$log_dir"

log_file="$log_dir/preprocess-array-task-${SLURM_JOB_ID:-job}_${array_task_id}.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES preprocess array task =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "sample_sheet=$sample_sheet"
echo "array_task_id=$array_task_id"
echo "output_dir=$output_dir"

if [[ -n "${SLURM_ENV_SETUP:-}" ]]; then
  echo "Running SLURM_ENV_SETUP"
  eval "$SLURM_ENV_SETUP"
fi

required_preprocess_tools=(bwa samtools bcftools gatk fastp)

shared_env_is_usable() {
  local prefix="$1"
  local tool_path=""

  for tool in "${required_preprocess_tools[@]}"; do
    tool_path="$prefix/bin/$tool"
    if [[ ! -x "$tool_path" ]]; then
      echo "Shared preprocess env missing required tool: $tool_path"
      return 1
    fi
  done

  return 0
}

sample_id="$(awk -F'\t' -v target="$array_task_id" 'NR == 1 { next } ++i == target { print $1; exit }' "$sample_sheet")"
if [[ -z "$sample_id" ]]; then
  echo "Could not resolve sample_id for array task $array_task_id" >&2
  exit 2
fi

echo "sample_id=$sample_id"

if [[ "$use_conda_pipeline" == "1" ]]; then
  if ! command -v conda >/dev/null 2>&1; then
    echo "conda is required when WES_PIPELINE_USE_CONDA=1" >&2
    exit 2
  fi

  mkdir -p "$(dirname "$shared_env_prefix")"
  lock_dir="${shared_env_prefix}.lock"
  channel_args=()
  for channel in $conda_channels; do
    channel_args+=(-c "$channel")
  done

  if ! shared_env_is_usable "$shared_env_prefix"; then
    if mkdir "$lock_dir" 2>/dev/null; then
      if [[ -d "$shared_env_prefix" ]]; then
        echo "Removing incomplete shared preprocess conda env: $shared_env_prefix"
        rm -rf "$shared_env_prefix"
      fi
      echo "Creating shared preprocess conda env: $shared_env_prefix"
      cleanup_lock() {
        rmdir "$lock_dir" 2>/dev/null || true
      }
      trap cleanup_lock EXIT
      conda create -y -p "$shared_env_prefix" "${channel_args[@]}" $conda_packages
      cleanup_lock
      trap - EXIT
    else
      echo "Waiting for shared preprocess conda env lock: $lock_dir"
      while [[ -d "$lock_dir" ]]; do
        sleep 15
      done
    fi
  fi

  export PATH="$shared_env_prefix/bin:$PATH"
fi

cmd=(
  bash "$project_dir/pipelines/wes-germline.sh"
  --sample-sheet "$sample_sheet"
  --out "${WES_STAGE_OUT_DIR:-$output_dir/results/preprocess-batch}"
  --ref "${WES_REF_PATH:?WES_REF_PATH is required}"
  --bed "${WES_BED_PATH:?WES_BED_PATH is required}"
  --stage preprocess
  --sample "$sample_id"
  --threads "${SLURM_CPUS_PER_TASK:-8}"
)

if [[ "${WES_SKIP_FASTQC:-1}" == "1" ]]; then
  cmd+=(--skip-fastqc)
fi
if [[ "${WES_SKIP_BQSR_PREPROCESS:-1}" == "1" ]]; then
  cmd+=(--skip-bqsr)
fi

echo "Running preprocess command: ${cmd[*]}"
"${cmd[@]}"

echo "Preprocess task finished: $sample_id"

