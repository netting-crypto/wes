#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/reports}"
storage_state_path="${STORAGE_STATE_PATH:-$project_dir/data/storage-state.json}"
template_dir="${TEMPLATE_DIR:-$project_dir/templates}"

cd "$project_dir"

if [[ -n "${SLURM_ENV_SETUP:-}" ]]; then
  echo "Running SLURM_ENV_SETUP"
  eval "$SLURM_ENV_SETUP"
fi

mkdir -p "$output_dir" "$(dirname "$storage_state_path")"

if [[ -n "${STORAGE_STATE_JSON:-}" && ! -f "$storage_state_path" ]]; then
  printf '%s' "$STORAGE_STATE_JSON" > "$storage_state_path"
fi

if [[ ! -f "$storage_state_path" ]]; then
  echo "Missing storage state file: $storage_state_path" >&2
  exit 1
fi

if [[ ! -d "$template_dir" ]]; then
  echo "Missing template directory: $template_dir" >&2
  exit 1
fi

if [[ "${SKIP_NPM_CI:-0}" != "1" || ! -d node_modules ]]; then
  npm ci
fi

if [[ "${SKIP_PLAYWRIGHT_INSTALL:-0}" != "1" ]]; then
  npx playwright install chromium
fi

npm run pipeline