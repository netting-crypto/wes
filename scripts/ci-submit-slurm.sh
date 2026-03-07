#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/reports}"
storage_state_path="${STORAGE_STATE_PATH:-$project_dir/data/storage-state.json}"
slurm_log_dir="${SLURM_LOG_DIR:-$project_dir/output/slurm}"
slurm_job_name="${SLURM_JOB_NAME:-wes-pipeline}"
slurm_partition="${SLURM_PARTITION:-}"
slurm_account="${SLURM_ACCOUNT:-}"
slurm_qos="${SLURM_QOS:-}"
slurm_time="${SLURM_TIME:-}"
slurm_cpus="${SLURM_CPUS_PER_TASK:-2}"
slurm_mem="${SLURM_MEM:-4G}"
slurm_extra_args="${SLURM_EXTRA_ARGS:-}"

mkdir -p "$slurm_log_dir" "$output_dir" "$(dirname "$storage_state_path")"

if [[ -n "${STORAGE_STATE_JSON:-}" ]]; then
  printf '%s' "$STORAGE_STATE_JSON" > "$storage_state_path"
fi

submit_cmd=(
  sbatch
  --wait
  --parsable
  --export=ALL
  --chdir "$project_dir"
  --job-name "$slurm_job_name"
  --cpus-per-task "$slurm_cpus"
  --mem "$slurm_mem"
  --output "$slurm_log_dir/slurm-%j.out"
  --error "$slurm_log_dir/slurm-%j.err"
)

if [[ -n "$slurm_time" ]]; then
  submit_cmd+=(--time "$slurm_time")
fi

if [[ -n "$slurm_partition" ]]; then
  submit_cmd+=(--partition "$slurm_partition")
fi

if [[ -n "$slurm_account" ]]; then
  submit_cmd+=(--account "$slurm_account")
fi

if [[ -n "$slurm_qos" ]]; then
  submit_cmd+=(--qos "$slurm_qos")
fi

if [[ -n "$slurm_extra_args" ]]; then
  extra_parts=()
  read -r -a extra_parts <<< "$slurm_extra_args"
  submit_cmd+=("${extra_parts[@]}")
fi

submit_cmd+=("$project_dir/scripts/slurm-job.sh")

echo "Submitting Slurm job from $project_dir"
echo "SBATCH command: ${submit_cmd[*]}"

set +e
submit_output="$("${submit_cmd[@]}" 2>&1)"
submit_status=$?
set -e

printf '%s\n' "$submit_output" > "$slurm_log_dir/submit.log"

if [[ -n "$submit_output" ]]; then
  printf '%s\n' "$submit_output"
fi

job_id="$(printf '%s\n' "$submit_output" | sed -n '1s/^\([0-9][0-9]*\).*/\1/p')"
if [[ -n "$job_id" ]]; then
  printf '%s\n' "$job_id" > "$slurm_log_dir/job-id.txt"
  echo "Slurm job id: $job_id"
else
  echo "Could not parse a Slurm job id from sbatch output" >&2
  submit_status=1
fi

stdout_log=""
stderr_log=""
if [[ -n "$job_id" ]]; then
  stdout_log="$slurm_log_dir/slurm-${job_id}.out"
  stderr_log="$slurm_log_dir/slurm-${job_id}.err"
fi

if [[ $submit_status -ne 0 ]]; then
  echo "Slurm job failed with exit status $submit_status"
  if [[ -n "$stdout_log" && -f "$stdout_log" ]]; then
    echo "--- Slurm stdout (tail) ---"
    tail -n 200 "$stdout_log"
  fi
  if [[ -n "$stderr_log" && -f "$stderr_log" ]]; then
    echo "--- Slurm stderr (tail) ---"
    tail -n 200 "$stderr_log"
  fi
  exit "$submit_status"
fi

if [[ -d "$output_dir" ]]; then
  echo "Artifacts prepared in $output_dir"
  find "$output_dir" -maxdepth 2 -type f | sort
fi