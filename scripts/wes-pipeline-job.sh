#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
log_dir="$output_dir/$logs_subdir"
use_conda_pipeline="${WES_PIPELINE_USE_CONDA:-1}"
conda_env_prefix="${WES_PIPELINE_CONDA_ENV_PREFIX:-${TMPDIR:-/tmp}/wes-pipeline-conda-${SLURM_JOB_ID:-$$}}"
shared_env_prefix="${WES_PIPELINE_SHARED_CONDA_ENV_PREFIX:-$output_dir/shared-envs/pipeline-conda}"
conda_pkgs_dir="${WES_PIPELINE_CONDA_PKGS_DIR:-$output_dir/shared-envs/conda-pkgs}"
conda_channels="${WES_CONDA_CHANNELS:-conda-forge bioconda}"
conda_packages="${WES_PIPELINE_CONDA_PACKAGES:-bwa samtools bcftools gatk4 htslib fastp fastqc}"
generate_sample_sheet="${WES_GENERATE_SAMPLE_SHEET_FROM_FASTQ:-0}"
generated_sample_sheet_path="${WES_GENERATED_SAMPLE_SHEET_PATH:-$project_dir/config/wes/samples.generated.tsv}"
reuse_shared_conda="${WES_PIPELINE_REUSE_SHARED_CONDA:-1}"
base_bed_path="${WES_BED_PATH:-}"
extra_interval_bed="${WES_EXTRA_INTERVAL_BED:-}"
merged_bed_path="${WES_MERGED_BED_PATH:-$output_dir/targets/merged_targets.bed}"

mkdir -p "$output_dir" "$log_dir"

log_file="$log_dir/pipeline-wrapper.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES pipeline wrapper =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "project_dir=$project_dir"
echo "output_dir=$output_dir"
echo "use_conda_pipeline=$use_conda_pipeline"

required_pipeline_tools=(bwa samtools bcftools gatk fastp fastqc)

resolve_path_if_needed() {
  local input_path="$1"
  if [[ -z "$input_path" ]]; then
    return 0
  fi
  if [[ "$input_path" = /* ]]; then
    printf '%s\n' "$input_path"
  else
    printf '%s\n' "$project_dir/$input_path"
  fi
}

shared_env_is_usable() {
  local prefix="$1"
  local tool_path=""

  for tool in "${required_pipeline_tools[@]}"; do
    tool_path="$prefix/bin/$tool"
    if [[ ! -x "$tool_path" ]]; then
      echo "Shared pipeline env missing required tool: $tool_path"
      return 1
    fi
  done

  return 0
}

if [[ "$use_conda_pipeline" == "1" ]]; then
  if ! command -v conda >/dev/null 2>&1; then
    echo "conda is required when WES_PIPELINE_USE_CONDA=1" >&2
    exit 2
  fi

  channel_args=()
  for channel in $conda_channels; do
    channel_args+=(-c "$channel")
  done

  echo "conda_channels=$conda_channels"
  echo "conda_packages=$conda_packages"
  mkdir -p "$conda_pkgs_dir"
  export CONDA_PKGS_DIRS="$conda_pkgs_dir"
  echo "conda_pkgs_dir=$CONDA_PKGS_DIRS"

  if [[ "$reuse_shared_conda" == "1" ]]; then
    mkdir -p "$(dirname "$shared_env_prefix")"
    lock_dir="${shared_env_prefix}.lock"
    conda_env_prefix="$shared_env_prefix"

    while ! shared_env_is_usable "$conda_env_prefix"; do
      if mkdir "$lock_dir" 2>/dev/null; then
        if [[ -d "$conda_env_prefix" ]]; then
          echo "Removing incomplete shared pipeline conda env: $conda_env_prefix"
          rm -rf "$conda_env_prefix"
        fi
        echo "Creating shared pipeline conda env: $conda_env_prefix"
        cleanup_lock() {
          rmdir "$lock_dir" 2>/dev/null || true
        }
        trap cleanup_lock EXIT
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
        cleanup_lock
        trap - EXIT
      else
        echo "Waiting for shared pipeline conda env lock: $lock_dir"
        while [[ -d "$lock_dir" ]]; do
          sleep 15
        done
      fi
    done

    echo "Reusing shared pipeline conda env: $conda_env_prefix"
  else
    rm -rf "$conda_env_prefix"
    echo "Creating temporary pipeline conda env: $conda_env_prefix"
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
  fi

  export PATH="$conda_env_prefix/bin:$PATH"
fi

if [[ "$generate_sample_sheet" == "1" ]]; then
  echo "Generating sample sheet from FASTQ directory"
  bash "$project_dir/scripts/generate-wes-sample-sheet.sh" \
    --fastq-dir "${WES_FASTQ_DIR:?WES_FASTQ_DIR is required when WES_GENERATE_SAMPLE_SHEET_FROM_FASTQ=1}" \
    --out "$generated_sample_sheet_path"
  export WES_SAMPLE_SHEET="$generated_sample_sheet_path"
  echo "WES_SAMPLE_SHEET=$WES_SAMPLE_SHEET"
fi

resolved_base_bed="$(resolve_path_if_needed "$base_bed_path")"
resolved_extra_bed="$(resolve_path_if_needed "$extra_interval_bed")"
if [[ -n "$resolved_base_bed" && -n "$resolved_extra_bed" ]]; then
  mkdir -p "$(dirname "$merged_bed_path")"
  echo "Merging target BED with extra hotspot BED"
  echo "base_bed=$resolved_base_bed"
  echo "extra_bed=$resolved_extra_bed"
  bash "$project_dir/scripts/wes-merge-bed.sh" \
    --base-bed "$resolved_base_bed" \
    --extra-bed "$resolved_extra_bed" \
    --output-bed "$merged_bed_path"
  export WES_BED_PATH="$merged_bed_path"
  echo "effective_bed=$WES_BED_PATH"
  if [[ -n "${WES_PIPELINE_CMD:-}" ]]; then
    WES_PIPELINE_CMD="${WES_PIPELINE_CMD/--bed \"$resolved_base_bed\"/--bed \"$WES_BED_PATH\"}"
    WES_PIPELINE_CMD="${WES_PIPELINE_CMD/--bed \"$base_bed_path\"/--bed \"$WES_BED_PATH\"}"
  fi
fi

echo "Running pipeline command"
echo "WES_PIPELINE_CMD=${WES_PIPELINE_CMD:?WES_PIPELINE_CMD is required when WES_MODE=pipeline}"
# Use a non-login shell so the conda-backed PATH we just prepared is preserved.
bash -c "$WES_PIPELINE_CMD"

if [[ "$use_conda_pipeline" == "1" && "$reuse_shared_conda" != "1" && -d "$conda_env_prefix" ]]; then
  echo "Cleaning temporary pipeline conda env: $conda_env_prefix"
  rm -rf "$conda_env_prefix"
fi

echo "Pipeline wrapper finished."

