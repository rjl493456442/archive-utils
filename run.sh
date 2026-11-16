#!/usr/bin/env bash
# Run on Ubuntu. Keep this foreground process in tmux during a long sync.
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
if [[ ${1:-} == --dry-run ]]; then DRY_RUN=1; shift; fi
CONFIG=${1:-config.env}
[[ $# -le 1 ]] || { echo 'Usage: ./run.sh [--dry-run] [config.env]' >&2; exit 1; }
[[ -f $CONFIG ]] || { echo 'Copy config.env.example to config.env and set the paths and target hash.' >&2; exit 1; }
# This is a trusted shell configuration file.
source "$CONFIG"
: "${GETH_BIN:=./geth/build/bin/geth}"
: "${DATADIR:?Set DATADIR to an existing directory on the SSD}"
: "${ANCIENT_DIR:?Set ANCIENT_DIR to an existing directory on the HDD}"
: "${RUN_ROOT:?Set RUN_ROOT to a directory on the SSD for logs and metrics}"
: "${TARGET_HASH:?Set TARGET_HASH to a trusted mainnet block hash}"
: "${CACHE_MB:=4096}" "${MEMORY_LIMIT_MB:=}"
[[ $TARGET_HASH =~ ^0x[0-9a-fA-F]{64}$ && $TARGET_HASH != 0x0000000000000000000000000000000000000000000000000000000000000000 ]] || { echo 'TARGET_HASH must be a nonzero 32-byte hash, not a block number.' >&2; exit 1; }
[[ $CACHE_MB =~ ^[1-9][0-9]*$ ]] || { echo 'CACHE_MB must be a positive integer.' >&2; exit 1; }
[[ -z $MEMORY_LIMIT_MB || $MEMORY_LIMIT_MB =~ ^[1-9][0-9]*$ ]] || { echo 'MEMORY_LIMIT_MB must be empty or a positive integer.' >&2; exit 1; }
[[ -x $GETH_BIN ]] || { echo "Build Geth first: $GETH_BIN is not executable." >&2; exit 1; }
[[ -d $DATADIR && -d $ANCIENT_DIR ]] || { echo 'Mount the SSD/HDD and create DATADIR and ANCIENT_DIR first.' >&2; exit 1; }
DATADIR=$(cd "$DATADIR" && pwd -P)
ANCIENT_DIR=$(cd "$ANCIENT_DIR" && pwd -P)
[[ $DATADIR != "$ANCIENT_DIR" ]] || { echo 'DATADIR and ANCIENT_DIR must be different.' >&2; exit 1; }

args=(
  --mainnet --datadir "$DATADIR" --datadir.ancient "$ANCIENT_DIR"
  --state.scheme path --syncmode full --synctarget "$TARGET_HASH"
  --gcmode archive --history.state 0 --history.trienode 0
  --history.trienode.full-value-checkpoint 8 --history.chain all
  --history.transactions 2350000 --history.logs.disable --cache.preimages
  --cache "$CACHE_MB"
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3
  --http.vhosts localhost,127.0.0.1 --ipcdisable
  --authrpc.addr 127.0.0.1 --authrpc.port 8551
  --metrics --metrics.addr 127.0.0.1 --metrics.port 6060
  --log.format json --verbosity 3
)
if [[ -n $MEMORY_LIMIT_MB ]]; then
  args+=(--memorylimit "$MEMORY_LIMIT_MB")
fi
help_text=$("$GETH_BIN" --help)
for arg in "${args[@]}"; do
  if [[ $arg == --* ]] && ! grep -Fq -- "$arg " <<< "$help_text"; then
    echo "Geth does not support required flag $arg; build a compatible official checkout." >&2
    exit 1
  fi
done
if (( DRY_RUN )); then
  printf '%q ' "$GETH_BIN" "${args[@]}"; printf '\n'
  exit 0
fi
[[ $(uname -s) == Linux ]] || { echo 'Run this script on Ubuntu/Linux.' >&2; exit 1; }
for tool in curl jq docker flock awk df stat; do command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }; done
[[ $(stat -c %d "$DATADIR") != "$(stat -c %d "$ANCIENT_DIR")" ]] || { echo 'SSD and HDD paths are on the same filesystem; check the mounts.' >&2; exit 1; }
exec 8>.run.lock
flock -n 8 || { echo 'Another run is using this repository.' >&2; exit 1; }
for port in 8545 8551 6060 30303; do
  if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "Port $port is already in use; stop the existing node first." >&2; exit 1
  fi
done
exec 9>"$DATADIR/.archive-run.lock"
flock -n 9 || { echo 'Another archive run holds this data directory.' >&2; exit 1; }
if [[ ! -f $DATADIR/.archive-run ]]; then
  [[ ! -d $DATADIR/geth/chaindata && -z $(ls -A "$ANCIENT_DIR") ]] || { echo 'First run requires fresh data directories; a pruned database cannot restore missing history.' >&2; exit 1; }
else
  [[ $(cat "$DATADIR/.archive-run") == "$ANCIENT_DIR" ]] || { echo 'The ancient path differs from the previous run.' >&2; exit 1; }
fi
mkdir -p "$RUN_ROOT"
RUN_ROOT=$(cd "$RUN_ROOT" && pwd -P)
export PROMETHEUS_DIR="$RUN_ROOT/metrics/data" TEXTFILE_DIR="$RUN_ROOT/metrics/textfile"
export LOCAL_UID=$(id -u) LOCAL_GID=$(id -g)
export DATADIR ANCIENT_DIR
mkdir -p "$PROMETHEUS_DIR" "$TEXTFILE_DIR"
rm -f "$TEXTFILE_DIR/archive.prom" "$TEXTFILE_DIR/archive.prom.tmp"
# The compose project must be unique on this host; endpoints use fixed local ports.
docker compose -p geth-archive config -q
docker compose -p geth-archive up -d
for attempt in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null; then break; fi
  [[ $attempt != 60 ]] || { echo 'Prometheus did not become ready.' >&2; exit 1; }
  sleep 1
done
RUN_DIR=$(mktemp -d "$RUN_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
START_EPOCH=$(date +%s)
printf '%q ' "$GETH_BIN" "${args[@]}" > "$RUN_DIR/command.txt"
printf '\n' >> "$RUN_DIR/command.txt"
"$GETH_BIN" version > "$RUN_DIR/geth-version.txt"
sha256sum "$GETH_BIN" > "$RUN_DIR/geth-sha256.txt"
printf '%s\n' "$ANCIENT_DIR" > "$DATADIR/.archive-run"
geth_pid= monitor_pid=
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n $geth_pid ]] && kill -0 "$geth_pid" 2>/dev/null; then
    echo 'Stopping Geth gracefully; waiting for database shutdown...'
    kill -INT "$geth_pid" 2>/dev/null || true
    wait "$geth_pid" || true
  fi
  if [[ -n $monitor_pid ]]; then
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  bash ./monitor.sh summary "$RUN_DIR" "$START_EPOCH" "Run stopped (exit $status)" || true
  echo "Run files: $RUN_DIR"
  echo 'Metrics remain available at http://127.0.0.1:9090. Stop them with: docker compose -p geth-archive down'
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$GETH_BIN" "${args[@]}" > "$RUN_DIR/geth.log" 2>&1 &
geth_pid=$!
printf '%s\n' "$geth_pid" > "$RUN_DIR/geth.pid"
bash ./monitor.sh "$RUN_DIR" "$geth_pid" "$START_EPOCH" "$TARGET_HASH" "$TEXTFILE_DIR" > "$RUN_DIR/monitor.log" 2>&1 8>&- 9>&- &
monitor_pid=$!
echo "Run directory: $RUN_DIR"
echo "Geth log: $RUN_DIR/geth.log"
echo 'Prometheus: http://127.0.0.1:9090 (SSH tunnel for remote access)'
echo 'A sync-summary.md will be written after the target and reported index backlog settle. The node keeps running.'
echo 'Press Ctrl-C to stop Geth and write a final summary.md.'
while kill -0 "$geth_pid" 2>/dev/null; do
  if ! kill -0 "$monitor_pid" 2>/dev/null; then
    echo 'Monitor exited unexpectedly; stopping Geth.' | tee -a "$RUN_DIR/monitor.log" >&2
    exit 1
  fi
  sleep 2 8>&- 9>&-
done
set +e
wait "$geth_pid"
result=$?
set -e
exit "$result"
