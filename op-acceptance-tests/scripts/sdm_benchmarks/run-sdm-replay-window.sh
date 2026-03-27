#!/usr/bin/env bash
set -euo pipefail

# Run sdm-replay over a recent block window and generate a PNG report.
#
# Examples:
#   op-acceptance-tests/scripts/sdm_benchmarks/run-sdm-replay-window.sh
#   op-acceptance-tests/scripts/sdm_benchmarks/run-sdm-replay-window.sh --count 100 \
#     --rpc http://100.126.224.125:8545 \
#     --jsonl-out /tmp/sdm-replay-latest-new.jsonl \
#     --png-out /tmp/sdm-replay-latest-new.png
#   BLOCK_COUNT=250 op-acceptance-tests/scripts/sdm_benchmarks/run-sdm-replay-window.sh
#   op-acceptance-tests/scripts/sdm_benchmarks/run-sdm-replay-window.sh --chunk-size 5000 --workers 10
#   op-acceptance-tests/scripts/sdm_benchmarks/run-sdm-replay-window.sh --refresh-cache -- --compare-rpc-receipts

RPC_URL="${RPC_URL:-http://100.126.224.125:8545}"
BLOCK_COUNT="${BLOCK_COUNT:-100}"
JSONL_OUT="${JSONL_OUT:-}"
PNG_OUT="${PNG_OUT:-}"
CACHE_DIR="${CACHE_DIR:-/tmp/sdm-replay-cache}"
CHUNK_SIZE="${CHUNK_SIZE:-1000}"
CHUNK_WORKERS="${CHUNK_WORKERS:-10}"
MIN_BLOCK_GAS_USED="${MIN_BLOCK_GAS_USED:-1000000}"
REFRESH_CACHE="${REFRESH_CACHE:-false}"
GOCACHE_DIR="${GOCACHE_DIR:-/tmp/optimism-codex-gocache}"
GO_BIN="${GO_BIN:-go}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"

REPLAY_EXTRA_ARGS=()
ACTIVE_PIDS=()
FAILED=false
JSONL_OUT_EXPLICIT=false
PNG_OUT_EXPLICIT=false

usage() {
  cat <<EOF
Usage: $0 [options] [-- <extra sdm-replay args>]

Options:
  --rpc URL             RPC endpoint (default: ${RPC_URL})
  --count N             Number of latest blocks to replay (default: ${BLOCK_COUNT})
  --jsonl-out PATH      Final merged JSONL output path (default: auto-generated from range/count/min gas)
  --png-out PATH        PNG output path (default: auto-generated from range/count/min gas)
  --cache-dir PATH      Directory for reusable chunk JSONL files (default: ${CACHE_DIR})
  --chunk-size N        Blocks per replay chunk for progress/caching (default: ${CHUNK_SIZE})
  --workers N           Concurrent chunk replay workers (default: ${CHUNK_WORKERS})
  --min-block-gas-used N  Only keep replayed blocks with at least this gas used in final JSONL/PNG (default: ${MIN_BLOCK_GAS_USED})
  --refresh-cache       Ignore cached chunks and fetch them again
  --gocache PATH        GOCACHE directory for go run (default: ${GOCACHE_DIR})
  --go-bin PATH         Go binary to use (default: ${GO_BIN})
  --python-bin PATH     Python binary to use (default: ${PYTHON_BIN})
  -h, --help            Show this help

Any arguments after -- are passed through to ./op-chain-ops/cmd/sdm-replay.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc)
      RPC_URL="$2"
      shift 2
      ;;
    --count)
      BLOCK_COUNT="$2"
      shift 2
      ;;
    --jsonl-out)
      JSONL_OUT="$2"
      JSONL_OUT_EXPLICIT=true
      shift 2
      ;;
    --png-out)
      PNG_OUT="$2"
      PNG_OUT_EXPLICIT=true
      shift 2
      ;;
    --cache-dir)
      CACHE_DIR="$2"
      shift 2
      ;;
    --chunk-size)
      CHUNK_SIZE="$2"
      shift 2
      ;;
    --workers)
      CHUNK_WORKERS="$2"
      shift 2
      ;;
    --min-block-gas-used)
      MIN_BLOCK_GAS_USED="$2"
      shift 2
      ;;
    --refresh-cache)
      REFRESH_CACHE=true
      shift
      ;;
    --gocache)
      GOCACHE_DIR="$2"
      shift 2
      ;;
    --go-bin)
      GO_BIN="$2"
      shift 2
      ;;
    --python-bin)
      PYTHON_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      REPLAY_EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$BLOCK_COUNT" =~ ^[0-9]+$ ]] || [[ "$BLOCK_COUNT" -lt 1 ]]; then
  echo "Error: --count must be a positive integer" >&2
  exit 1
fi
if ! [[ "$CHUNK_SIZE" =~ ^[0-9]+$ ]] || [[ "$CHUNK_SIZE" -lt 1 ]]; then
  echo "Error: --chunk-size must be a positive integer" >&2
  exit 1
fi
if ! [[ "$CHUNK_WORKERS" =~ ^[0-9]+$ ]] || [[ "$CHUNK_WORKERS" -lt 1 ]]; then
  echo "Error: --workers must be a positive integer" >&2
  exit 1
fi
if ! [[ "$MIN_BLOCK_GAS_USED" =~ ^[0-9]+$ ]]; then
  echo "Error: --min-block-gas-used must be a non-negative integer" >&2
  exit 1
fi
if [[ ! -d "$REPO_ROOT/op-chain-ops/cmd/sdm-replay" ]]; then
  echo "Error: could not locate repo root from script path: $REPO_ROOT" >&2
  exit 1
fi

mkdir -p "$GOCACHE_DIR"
mkdir -p "$CACHE_DIR"

cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

block_response=$(curl -fsS \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$RPC_URL")

block_hex=$(
  "$PYTHON_BIN" - "$block_response" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if "error" in payload:
    raise SystemExit(f"RPC error: {payload['error']}")
result = payload.get("result")
if not isinstance(result, str) or not result.startswith("0x"):
    raise SystemExit(f"Unexpected eth_blockNumber response: {payload}")
print(result)
PY
)

latest_block=$((16#${block_hex#0x}))
from_block=$((latest_block - BLOCK_COUNT + 1))
if (( from_block < 0 )); then
  from_block=0
fi
actual_block_count=$((latest_block - from_block + 1))

if [[ "$JSONL_OUT_EXPLICIT" != "true" ]] || [[ "$PNG_OUT_EXPLICIT" != "true" ]]; then
  auto_base="/tmp/sdm-replay-${from_block}-${latest_block}-count-${actual_block_count}-min-gas-${MIN_BLOCK_GAS_USED}"
  if [[ "$JSONL_OUT_EXPLICIT" != "true" ]]; then
    JSONL_OUT="${auto_base}.jsonl"
  fi
  if [[ "$PNG_OUT_EXPLICIT" != "true" ]]; then
    PNG_OUT="${auto_base}.png"
  fi
fi

mkdir -p "$(dirname "$JSONL_OUT")"
mkdir -p "$(dirname "$PNG_OUT")"

chunk_starts=()
chunk_ends=()
chunk_paths=()
next_chunk_start=$from_block
while (( next_chunk_start <= latest_block )); do
  next_chunk_end=$((next_chunk_start + CHUNK_SIZE - 1))
  if (( next_chunk_end > latest_block )); then
    next_chunk_end=$latest_block
  fi
  chunk_starts+=("$next_chunk_start")
  chunk_ends+=("$next_chunk_end")
  next_chunk_start=$((next_chunk_end + 1))
done
total_chunks=${#chunk_starts[@]}

config_hash_cmd=(
  "$PYTHON_BIN" - "$RPC_URL" "$REPO_ROOT"
)
if (( ${#REPLAY_EXTRA_ARGS[@]} > 0 )); then
  config_hash_cmd+=("${REPLAY_EXTRA_ARGS[@]}")
fi
config_hash=$(
  "${config_hash_cmd[@]}" <<'PY'
import hashlib
import json
import subprocess
import sys

rpc_url = sys.argv[1]
repo_root = sys.argv[2]
extra_args = sys.argv[3:]
commit = "unknown"
try:
    commit = subprocess.check_output(["git", "-C", repo_root, "rev-parse", "HEAD"], text=True).strip()
except Exception:
    pass
payload = {
    "rpc_url": rpc_url,
    "extra_args": extra_args,
    "commit": commit,
}
print(hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:16])
PY
)
cache_run_dir="${CACHE_DIR}/${config_hash}"
state_dir="${cache_run_dir}/.state"
log_dir="${cache_run_dir}/.logs"
mkdir -p "$cache_run_dir" "$state_dir" "$log_dir"

validate_chunk_cache() {
  local path="$1"
  local expected_from="$2"
  local expected_to="$3"

  "$PYTHON_BIN" - "$path" "$expected_from" "$expected_to" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_from = int(sys.argv[2])
expected_to = int(sys.argv[3])

if not path.exists() or path.stat().st_size == 0:
    raise SystemExit(1)

run_config = None
summary = None
with path.open() as f:
    for raw_line in f:
        line = raw_line.strip()
        if not line:
            continue
        rec = json.loads(line)
        rec_type = rec.get("type")
        if rec_type == "run_config":
            run_config = rec
        elif rec_type == "summary":
            summary = rec

if run_config is None or summary is None:
    raise SystemExit(1)
if int(summary.get("from_block", -1)) != expected_from:
    raise SystemExit(1)
if int(summary.get("to_block", -1)) != expected_to:
    raise SystemExit(1)
if int(run_config.get("resolved_from_block", -1)) != expected_from:
    raise SystemExit(1)
if int(run_config.get("resolved_to_block", -1)) != expected_to:
    raise SystemExit(1)
PY
}

merge_chunk_jsonl() {
  local output_path="$1"
  local range_from="$2"
  local range_to="$3"
  local min_block_gas_used="$4"
  shift 4

  "$PYTHON_BIN" - "$output_path" "$range_from" "$range_to" "$min_block_gas_used" "$@" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
range_from = int(sys.argv[2])
range_to = int(sys.argv[3])
min_block_gas_used = int(sys.argv[4])
chunk_paths = [Path(p) for p in sys.argv[5:]]

if not chunk_paths:
    raise SystemExit("No chunk files provided")

first_run_config = None
body_records = []
summary_totals = {
    "blocks_processed": 0,
    "blocks_skipped": 0,
    "blocks_with_sdm_tx": 0,
    "tx_count_total": 0,
    "tx_count_user": 0,
    "total_gas_used": 0,
    "replay_refund_total": 0,
    "node_receipt_refund_total": 0,
    "payload_refund_total": 0,
    "effective_gas_total": 0,
    "mismatch_count": 0,
}
weighted_refund_ratio_sum = 0.0
filtered_out_blocks = 0

for chunk_path in chunk_paths:
    tx_records_by_block = {}
    block_records = {}
    mismatch_records_by_block = {}
    run_config = None
    summary = None
    with chunk_path.open() as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            rec = json.loads(line)
            rec_type = rec.get("type")
            if rec_type == "run_config":
                run_config = rec
            elif rec_type == "summary":
                summary = rec
            elif rec_type == "tx":
                tx_records_by_block.setdefault(int(rec["block_num"]), []).append(rec)
            elif rec_type == "mismatch":
                mismatch_records_by_block.setdefault(int(rec["block_num"]), []).append(rec)
            elif rec_type == "block":
                block_records[int(rec["block_num"])] = rec
    if run_config is None or summary is None:
        raise SystemExit(f"Invalid chunk file: {chunk_path}")
    if first_run_config is None:
        first_run_config = run_config

    for block_num in sorted(block_records):
        block_rec = block_records[block_num]
        block_gas_used = int(block_rec.get("block_gas_used", 0))
        if block_gas_used < min_block_gas_used:
            filtered_out_blocks += 1
            continue

        body_records.extend(tx_records_by_block.get(block_num, []))
        body_records.append(block_rec)
        body_records.extend(mismatch_records_by_block.get(block_num, []))

        summary_totals["blocks_processed"] += 1
        summary_totals["tx_count_total"] += int(block_rec.get("tx_count_total", 0))
        summary_totals["tx_count_user"] += int(block_rec.get("tx_count_user", 0))
        summary_totals["total_gas_used"] += int(block_rec.get("block_gas_used", 0))
        summary_totals["replay_refund_total"] += int(block_rec.get("replay_refund_total", 0))
        summary_totals["node_receipt_refund_total"] += int(block_rec.get("node_receipt_refund_total", 0))
        summary_totals["payload_refund_total"] += int(block_rec.get("payload_refund_total", 0))
        summary_totals["effective_gas_total"] += int(block_rec.get("block_effective_gas", 0))
        summary_totals["mismatch_count"] += int(block_rec.get("mismatch_count", 0))
        if bool(block_rec.get("sdm_tx_present", False)):
            summary_totals["blocks_with_sdm_tx"] += 1
        weighted_refund_ratio_sum += float(block_rec.get("avg_refund_ratio", 0.0)) * int(block_rec.get("tx_count_user", 0))

merged_run_config = dict(first_run_config)
merged_run_config["from_block"] = str(range_from)
merged_run_config["to_block"] = str(range_to)
merged_run_config["resolved_from_block"] = range_from
merged_run_config["resolved_to_block"] = range_to
merged_run_config["min_block_gas_used"] = min_block_gas_used

merged_summary = {
    "type": "summary",
    "from_block": range_from,
    "to_block": range_to,
    **summary_totals,
    "replay_mode": merged_run_config.get("replay_mode", "counterfactual_enabled"),
    "filtered_out_blocks": filtered_out_blocks,
    "min_block_gas_used": min_block_gas_used,
}
merged_summary["total_refund_ratio"] = (
    merged_summary["replay_refund_total"] / merged_summary["total_gas_used"]
    if merged_summary["total_gas_used"]
    else 0.0
)
merged_summary["avg_refund_ratio"] = (
    weighted_refund_ratio_sum / merged_summary["tx_count_user"]
    if merged_summary["tx_count_user"]
    else 0.0
)

if merged_summary["blocks_processed"] == 0:
    raise SystemExit(
        f"No blocks matched min_block_gas_used={min_block_gas_used} in requested range {range_from}..{range_to}"
    )

with output_path.open("w") as out:
    out.write(json.dumps(merged_run_config) + "\n")
    for rec in body_records:
        out.write(json.dumps(rec) + "\n")
    out.write(json.dumps(merged_summary) + "\n")
PY
}

format_duration() {
  local total_seconds="$1"
  if [[ -z "$total_seconds" ]] || (( total_seconds < 0 )); then
    total_seconds=0
  fi
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))
  printf "%02dh:%02dm:%02ds" "$hours" "$minutes" "$seconds"
}

print_status() {
  local current_done_blocks="$1"
  local current_total_blocks="$2"
  local running_jobs="$3"
  local now_ts="$4"
  local elapsed_since_start=$((now_ts - script_start_ts))
  local eta_text="unknown"
  local throughput_text="warming up"
  local progress_pct

  if (( fetched_completed_blocks > 0 )) && (( elapsed_since_start > 0 )); then
    local remaining_blocks=$((current_total_blocks - current_done_blocks))
    local eta_seconds
    if (( remaining_blocks < 0 )); then
      remaining_blocks=0
    fi
    eta_seconds=$(awk -v rem="$remaining_blocks" -v blocks="$fetched_completed_blocks" -v secs="$elapsed_since_start" 'BEGIN { printf "%d", (rem * secs) / blocks }')
    eta_text=$(format_duration "$eta_seconds")
    throughput_text=$(awk -v blocks="$fetched_completed_blocks" -v secs="$elapsed_since_start" 'BEGIN { printf "%.1f blk/s", blocks / secs }')
  fi

  progress_pct=$(awk -v done="$current_done_blocks" -v total="$current_total_blocks" 'BEGIN { printf "%.1f", (done / total) * 100 }')
  echo "Status: ${current_done_blocks} / ${current_total_blocks} blocks (${progress_pct}%) | chunks ${completed_chunks}/${total_chunks} complete | running ${running_jobs} | cache ${cached_chunks} reused | fetched ${fetched_completed_chunks}/${fetched_chunks_total} complete | elapsed $(format_duration "$elapsed_since_start") | ETA ${eta_text} | throughput ${throughput_text}"
}

run_chunk_job() {
  local chunk_start="$1"
  local chunk_end="$2"
  local chunk_path="$3"
  local state_path="$4"
  local log_path="$5"
  local tmp_chunk_path="${chunk_path}.partial"
  local start_ts end_ts elapsed

  start_ts=$(date +%s)
  rm -f "$tmp_chunk_path"

  replay_cmd=(
    env GOCACHE="$GOCACHE_DIR"
    "$GO_BIN" run ./op-chain-ops/cmd/sdm-replay
    --rpc "$RPC_URL"
    --from-block "$chunk_start"
    --to-block "$chunk_end"
    --out "$tmp_chunk_path"
  )
  if (( ${#REPLAY_EXTRA_ARGS[@]} > 0 )); then
    replay_cmd+=("${REPLAY_EXTRA_ARGS[@]}")
  fi

  if (
    cd "$REPO_ROOT" &&
    "${replay_cmd[@]}"
  ) >"$log_path" 2>&1; then
    mv "$tmp_chunk_path" "$chunk_path"
    if validate_chunk_cache "$chunk_path" "$chunk_start" "$chunk_end"; then
      end_ts=$(date +%s)
      elapsed=$((end_ts - start_ts))
      printf 'done %s\n' "$elapsed" > "$state_path"
      return 0
    fi
    echo "cache_validation_failed" >> "$log_path"
  fi

  rm -f "$tmp_chunk_path"
  printf 'error\n' > "$state_path"
  return 1
}

reap_finished_pids() {
  local still_running=()
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      still_running+=("$pid")
    fi
  done
  ACTIVE_PIDS=("${still_running[@]:-}")
}

pending_indices=()
state_paths=()
log_paths=()
chunk_done_accounted=()
completed_blocks=0
completed_chunks=0
cached_chunks=0
fetched_chunks_total=0
fetched_completed_chunks=0
fetched_completed_blocks=0
script_start_ts=$(date +%s)
last_status_ts=0

for ((idx = 0; idx < total_chunks; idx++)); do
  chunk_start="${chunk_starts[$idx]}"
  chunk_end="${chunk_ends[$idx]}"
  chunk_path="${cache_run_dir}/${chunk_start}-${chunk_end}.jsonl"
  state_path="${state_dir}/${chunk_start}-${chunk_end}.status"
  log_path="${log_dir}/${chunk_start}-${chunk_end}.log"

  chunk_paths+=("$chunk_path")
  state_paths+=("$state_path")
  log_paths+=("$log_path")
  chunk_done_accounted+=("0")
  rm -f "$state_path"

  if [[ "$REFRESH_CACHE" != "true" ]] && validate_chunk_cache "$chunk_path" "$chunk_start" "$chunk_end"; then
    cached_chunks=$((cached_chunks + 1))
    completed_chunks=$((completed_chunks + 1))
    completed_blocks=$((completed_blocks + chunk_end - chunk_start + 1))
    chunk_done_accounted[$idx]="1"
  else
    pending_indices+=("$idx")
    fetched_chunks_total=$((fetched_chunks_total + 1))
  fi
done

echo "RPC endpoint: ${RPC_URL}"
echo "Latest block: ${latest_block} (${block_hex})"
echo "Replay range: ${from_block}..${latest_block} (${actual_block_count} blocks)"
echo "Chunk size: ${CHUNK_SIZE} (${total_chunks} chunk(s))"
echo "Concurrent chunk workers: ${CHUNK_WORKERS}"
echo "Min block gas used in final report: ${MIN_BLOCK_GAS_USED}"
echo "Chunk cache dir: ${cache_run_dir}"
echo "Final JSONL output: ${JSONL_OUT}"
echo "PNG output: ${PNG_OUT}"
echo "Repo root: ${REPO_ROOT}"
if (( ${#REPLAY_EXTRA_ARGS[@]} > 0 )); then
  echo "Extra sdm-replay args: ${REPLAY_EXTRA_ARGS[*]}"
fi
echo "Preflight: ${cached_chunks} cached chunk(s), ${fetched_chunks_total} chunk(s) to fetch"
print_status "$completed_blocks" "$actual_block_count" 0 "$script_start_ts"

next_pending=0
while (( completed_chunks < total_chunks )); do
  reap_finished_pids

  while (( ${#ACTIVE_PIDS[@]} < CHUNK_WORKERS )) && (( next_pending < ${#pending_indices[@]} )); do
    idx="${pending_indices[$next_pending]}"
    next_pending=$((next_pending + 1))
    chunk_start="${chunk_starts[$idx]}"
    chunk_end="${chunk_ends[$idx]}"
    chunk_path="${chunk_paths[$idx]}"
    state_path="${state_paths[$idx]}"
    log_path="${log_paths[$idx]}"
    echo "Launching chunk [$((idx + 1))/${total_chunks}] ${chunk_start}..${chunk_end}"
    run_chunk_job "$chunk_start" "$chunk_end" "$chunk_path" "$state_path" "$log_path" &
    ACTIVE_PIDS+=("$!")
  done

  for ((idx = 0; idx < total_chunks; idx++)); do
    if [[ "${chunk_done_accounted[$idx]}" == "1" ]]; then
      continue
    fi
    state_path="${state_paths[$idx]}"
    if [[ ! -f "$state_path" ]]; then
      continue
    fi

    state_line=$(head -n 1 "$state_path" || true)
    case "$state_line" in
      done*)
        chunk_start="${chunk_starts[$idx]}"
        chunk_end="${chunk_ends[$idx]}"
        chunk_block_count=$((chunk_end - chunk_start + 1))
        chunk_done_accounted[$idx]="1"
        completed_chunks=$((completed_chunks + 1))
        completed_blocks=$((completed_blocks + chunk_block_count))
        fetched_completed_chunks=$((fetched_completed_chunks + 1))
        fetched_completed_blocks=$((fetched_completed_blocks + chunk_block_count))
        echo "Completed chunk [$((idx + 1))/${total_chunks}] ${chunk_start}..${chunk_end}"
        ;;
      error*)
        chunk_start="${chunk_starts[$idx]}"
        chunk_end="${chunk_ends[$idx]}"
        echo "Error: chunk [$((idx + 1))/${total_chunks}] ${chunk_start}..${chunk_end} failed" >&2
        echo "Log: ${log_paths[$idx]}" >&2
        tail -n 20 "${log_paths[$idx]}" >&2 || true
        FAILED=true
        break
        ;;
    esac
  done

  if [[ "$FAILED" == "true" ]]; then
    exit 1
  fi

  now_ts=$(date +%s)
  if (( now_ts - last_status_ts >= 10 )); then
    print_status "$completed_blocks" "$actual_block_count" "${#ACTIVE_PIDS[@]}" "$now_ts"
    last_status_ts=$now_ts
  fi

  if (( completed_chunks < total_chunks )); then
    sleep 1
  fi
done

reap_finished_pids

echo "Merging ${#chunk_paths[@]} chunk(s) into ${JSONL_OUT}"
merge_chunk_jsonl "$JSONL_OUT" "$from_block" "$latest_block" "$MIN_BLOCK_GAS_USED" "${chunk_paths[@]}"

echo "Rendering PNG report"
(
  cd "$REPO_ROOT"
  "$PYTHON_BIN" op-acceptance-tests/scripts/sdm_benchmarks/visualize.py \
    --input "$JSONL_OUT" \
    --output "$PNG_OUT"
)

echo "Done."
echo "Cache summary: ${cached_chunks} reused, ${fetched_completed_chunks} fetched"
echo ""
echo "open ${PNG_OUT}"
