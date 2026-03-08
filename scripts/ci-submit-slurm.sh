#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
slurm_log_dir="${SLURM_LOG_DIR:-$output_dir/slurm}"
result_subdir="${WES_RESULTS_SUBDIR:-results}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
result_dir="$output_dir/$result_subdir"
wes_logs_dir="$output_dir/$logs_subdir"
slurm_job_name="${SLURM_JOB_NAME:-wes-pipeline}"
slurm_partition="${SLURM_PARTITION:-}"
slurm_account="${SLURM_ACCOUNT:-}"
slurm_qos="${SLURM_QOS:-}"
slurm_time="${SLURM_TIME:-}"
slurm_nodes="${SLURM_NODES:-1}"
slurm_ntasks="${SLURM_NTASKS:-1}"
slurm_cpus="${SLURM_CPUS_PER_TASK:-16}"
slurm_mem="${SLURM_MEM:-64G}"
slurm_extra_args="${SLURM_EXTRA_ARGS:-}"

mkdir -p "$slurm_log_dir" "$result_dir" "$wes_logs_dir"
debug_log="$slurm_log_dir/submit.log"

# Clear inherited sbatch defaults so CI submission is driven only by explicit SLURM_* variables.
unset SBATCH_ACCOUNT SBATCH_QOS SBATCH_PARTITION SBATCH_TIME SBATCH_MEM_PER_CPU SBATCH_MEM_PER_NODE SBATCH_MEM_PER_GPU SBATCH_GPUS SBATCH_NODES SBATCH_NTASKS SBATCH_CPUS_PER_TASK

submit_cmd=(
  sbatch
  --wait
  --parsable
  --export=ALL
  --chdir "$project_dir"
  --job-name "$slurm_job_name"
  --nodes "$slurm_nodes"
  --ntasks "$slurm_ntasks"
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
{
  echo "Submitting WES Slurm job from $project_dir"
  echo "SBATCH command: ${submit_cmd[*]}"
  echo "--- type -a sbatch ---"
  type -a sbatch || true
  echo "--- Relevant environment variables ---"
  env | sort | grep -E '^(SBATCH|SLURM|WES|OUTPUT_DIR|PATH)=' || true
} > "$debug_log"

set +e
submit_output="$("${submit_cmd[@]}" 2>&1)"
submit_status=$?
set -e

printf '%s\n' "$submit_output" >> "$debug_log"

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

manifest="$output_dir/result-manifest.txt"
{
  echo "job_id=$job_id"
  echo "slurm_stdout=$stdout_log"
  echo "slurm_stderr=$stderr_log"
  echo "submit_log=$debug_log"
  echo "results_dir=$result_dir"
  echo "wes_logs_dir=$wes_logs_dir"
  echo "wes_mode=${WES_MODE:-smoke}"
} > "$manifest"

if command -v find >/dev/null 2>&1; then
  find "$output_dir" -maxdepth 3 -type f | sort > "$output_dir/tree.txt" || true
fi

echo "WES artifacts prepared in $output_dir"
