#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/reports}"
storage_state_path="${STORAGE_STATE_PATH:-$project_dir/data/storage-state.json}"
template_dir="${TEMPLATE_DIR:-$project_dir/templates}"
wes_mode="${WES_MODE:-smoke}"

cd "$project_dir"

if [[ -n "${SLURM_ENV_SETUP:-}" ]]; then
  echo "Running SLURM_ENV_SETUP"
  eval "$SLURM_ENV_SETUP"
fi

mkdir -p "$output_dir"

case "$wes_mode" in
  prepare-resources)
    bash "$project_dir/scripts/wes-prepare-resources-job.sh"
    ;;
  smoke)
    bash "$project_dir/scripts/wes-smoke-test.sh"
    ;;
  find-bed)
    bash "$project_dir/scripts/wes-find-bed.sh"
    ;;
  pipeline)
    bash -lc "${WES_PIPELINE_CMD:?WES_PIPELINE_CMD is required when WES_MODE=pipeline}"
    ;;
  *)
    echo "Unsupported WES_MODE: $wes_mode" >&2
    exit 2
    ;;
esac
