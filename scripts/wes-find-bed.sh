#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
log_dir="$output_dir/$logs_subdir"
summary="$output_dir/bed-search-summary.txt"

mkdir -p "$output_dir" "$log_dir"

log_file="$log_dir/find-bed.log"
exec > >(tee -a "$log_file") 2>&1

echo "== WES BED search =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"

declare -a SEARCH_ROOTS=()
for candidate in \
  "${WES_RESOURCE_BASE:-}" \
  "${WES_FASTQ_DIR:-}" \
  "/home/zhangmeigroup/luoxin23/resources" \
  "/home/zhangmeigroup/luoxin23/upload20251105" \
  "/home/zhangmeigroup/luoxin23"
do
  [[ -n "$candidate" ]] || continue
  if [[ -d "$candidate" ]]; then
    skip_candidate=0
    for seen in "${SEARCH_ROOTS[@]}"; do
      if [[ "$seen" == "$candidate" ]]; then
        skip_candidate=1
        break
      fi
    done
    if [[ "$skip_candidate" -eq 0 ]]; then
      SEARCH_ROOTS+=("$candidate")
    fi
  fi
done

echo "search_roots=${SEARCH_ROOTS[*]:-NONE}"

matches_file="$output_dir/bed-search-matches.txt"
: > "$matches_file"

for root in "${SEARCH_ROOTS[@]}"; do
  echo
  echo "== Searching under $root =="
  find "$root" -type f \( \
    -iname "*.bed" -o \
    -iname "*.bed.gz" -o \
    -iname "*.interval_list" -o \
    -iname "*target*" -o \
    -iname "*capture*" -o \
    -iname "*exome*" \
  \) 2>/dev/null | sort | head -n 200 | tee -a "$matches_file" || true
done

match_count="$(grep -c . "$matches_file" 2>/dev/null || true)"
{
  echo "date=$(date -Iseconds)"
  echo "log=$log_file"
  echo "matches_file=$matches_file"
  echo "match_count=$match_count"
} > "$summary"

echo
echo "BED search finished."
echo "Summary: $summary"
