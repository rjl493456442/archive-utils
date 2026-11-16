#!/usr/bin/env bash
# Prometheus is the sole Geth metrics consumer. This script only polls RPC/alerts.
set -uo pipefail
RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
PROM_URL=${PROM_URL:-http://127.0.0.1:9090}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-15}
READY_SECONDS=${READY_SECONDS:-360}
write_failed() { printf 'Monitor could not write its output; exiting.\n' >&2; exit 1; }

event() { # source state message
    jq -cn --argjson time "$(date +%s)" --arg source "$1" --arg state "$2" --arg message "$3" \
        '{timestamp:$time,source:$source,state:$state,message:$message}' >> "$RUN/alerts.jsonl" || write_failed
}

query() {
    curl -fsS --max-time 10 --get "$PROM_URL/api/v1/query" \
        --data-urlencode "query=$1" --data-urlencode "time=$END" |
        jq -e 'select(.status == "success") | .data.result'
}

summary() {
    RUN=$1; START=$2; END=$(date +%s)
    local reason=${3:-stopped} span=$((END - START)) result
    (( span > 0 )) || span=1
    RANGE="${span}s"
    statline() {
        local label=$1 expression=$2 units=$3 result
        if result=$(query "$expression") && [[ $(jq 'length' <<< "$result") -gt 0 ]]; then
            printf -- '- %s: %s %s\n' "$label" "$(jq -r '[.[].value[1]] | join(", ")' <<< "$result")" "$units"
        else
            printf -- '- %s: N/A (query failed or no samples).\n' "$label"
        fi
    }
    {
        printf '# Archive run summary\n\nReason: %s. Window: %s–%s Unix seconds (%ss).\n\n' "$reason" "$START" "$END" "$span"
        if [[ -s "$RUN/status.json" ]]; then
            printf 'Last monitor status:\n\n```json\n'; cat "$RUN/status.json"; printf '\n```\n\n'
        fi
        statline 'Retained monitor observations' "count_over_time(archive_monitor_timestamp_seconds[$RANGE])" samples
        statline 'Earliest retained monitor observation' "min_over_time(archive_monitor_timestamp_seconds[$RANGE])" 'Unix seconds'
        statline 'Geth CPU average (100% = one core)' "100 * avg_over_time(rate(archive_geth_cpu_seconds_total[1m])[$RANGE:15s])" '%'
        statline 'Geth CPU peak (sampled)' "100 * max_over_time(rate(archive_geth_cpu_seconds_total[1m])[$RANGE:15s])" '%'
        statline 'Geth RSS peak' "max_over_time(archive_geth_rss_bytes[$RANGE]) / 1073741824" GiB
        statline 'Host minimum MemAvailable' "min_over_time(node_memory_MemAvailable_bytes[$RANGE]) / 1073741824" GiB
        for disk in ssd hdd; do
            statline "$disk last filesystem available" "last_over_time(archive_disk_available_bytes{disk=\"$disk\"}[$RANGE]) / 1073741824" GiB
            statline "$disk minimum filesystem available" "100 * min_over_time(archive_disk_available_ratio{disk=\"$disk\"}[$RANGE])" '%'
        done
        statline 'Geth physical read bytes (Prometheus estimated increase)' "increase(archive_geth_read_bytes_total[$RANGE]) / 1073741824" GiB
        statline 'Geth physical write bytes (Prometheus estimated increase)' "increase(archive_geth_write_bytes_total[$RANGE]) / 1073741824" GiB
        printf '\nActual freezer size gauges (last sample):\n\n'
        if result=$(query "last_over_time({__name__=~\"eth_db_(state|trienode)(_mpt_|_)?ancient_size\"}[$RANGE])") && [[ $(jq 'length' <<< "$result") -gt 0 ]]; then
            jq -r '.[] | "- `\(.metric.__name__)`: \((.value[1] | tonumber) / 1073741824) GiB"' <<< "$result"
        else
            printf -- '- N/A (query failed or gauge unavailable).\n'
        fi
        printf '\nRecorded alert/anomaly transitions: %s. Geth error log lines: %s.\n' \
            "$(awk 'END {print NR+0}' "$RUN/alerts.jsonl" 2>/dev/null || printf unknown)" \
            "$(awk 'END {print NR+0}' "$RUN/geth-errors.log" 2>/dev/null || printf unknown)"
        printf '\nFull details: alerts.jsonl, geth-errors.log, and Prometheus. Filesystem space includes other files on the same device. CPU and I/O are observed load, not causal archive/index overhead. Freezer sizes do not measure historical lookup indexes in Pebble.\n'
        printf '\nStatistics cover retained observations only. Prometheus retention (default 30 days or 20 GB, whichever is reached first) and collection gaps can make these a partial-run report. Missing observations are not zero load; compare the earliest retained observation with the requested start.\n'
    } > "$RUN/summary.md.tmp" && mv "$RUN/summary.md.tmp" "$RUN/summary.md" || write_failed
}

if [[ ${1:-} == summary ]]; then
    [[ $# -ge 3 ]] || { echo 'usage: monitor.sh summary RUN_DIR START_EPOCH [reason]' >&2; exit 2; }
    summary "$2" "$3" "${4:-stopped}"
    exit
fi
[[ $# == 5 ]] || { echo 'usage: monitor.sh RUN_DIR GETH_PID START_EPOCH TARGET_HASH TEXTFILE_DIR' >&2; exit 2; }
RUN=$1; PID=$2; START=$3; TARGET=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]'); TEXTDIR=$5
mkdir -p "$RUN" "$TEXTDIR" || write_failed
touch "$RUN/alerts.jsonl" "$RUN/geth-errors.log" || write_failed
jq -n --argjson start "$START" --argjson pid "$PID" --arg target "$TARGET" \
    --arg prom_url "$PROM_URL" '{start:$start,geth_pid:$pid,target_hash:$target,prom_url:$prom_url}' > "$RUN/monitor-meta.json" || write_failed
[[ -s "$RUN/.active-alerts.json" ]] || { printf '{}\n' > "$RUN/.active-alerts.json" || write_failed; }
fault() { if [[ ! -e "$RUN/.fault-$1" ]]; then event "$1" firing "$2"; touch "$RUN/.fault-$1" || write_failed; fi; }
recover() { if [[ -e "$RUN/.fault-$1" ]]; then event "$1" resolved 'Collection recovered'; rm "$RUN/.fault-$1" || write_failed; fi; }
stop=0; sleep_pid=''
stop_monitor() { stop=1; [[ -z $sleep_pid ]] || kill "$sleep_pid" 2>/dev/null || true; }
trap stop_monitor TERM INT
offset=0; target_seen=0; ready_since=0; last_success=0
: > "$RUN/.log-pending" || write_failed
ticks=$(getconf CLK_TCK)

poll_alerts() {
    if curl -fsS --max-time 8 "$PROM_URL/api/v1/alerts" -o "$RUN/.alerts-response" &&
       jq -e '.status == "success" and (.data.alerts | type == "array")' "$RUN/.alerts-response" >/dev/null; then
        jq '.data.alerts | map(select(.state == "firing") | {key:(.labels | to_entries | sort_by(.key) | from_entries | tojson),value:.}) | from_entries' \
            "$RUN/.alerts-response" > "$RUN/.next-alerts.json" || write_failed
        jq -cn --argjson time "$NOW" --slurpfile old "$RUN/.active-alerts.json" --slurpfile new "$RUN/.next-alerts.json" '
            (($new[0]|keys[]) as $key | select($old[0][$key] == null) | {timestamp:$time,source:"prometheus",state:"firing",alert:$new[0][$key]}),
            (($old[0]|keys[]) as $key | select($new[0][$key] == null) | {timestamp:$time,source:"prometheus",state:"resolved",alert:$old[0][$key]})' >> "$RUN/alerts.jsonl" || write_failed
        mv "$RUN/.next-alerts.json" "$RUN/.active-alerts.json" || write_failed
        recover prometheus
        return 0
    fi
    fault prometheus 'Prometheus alerts query failed'
    return 1
}

filter_errors() {
    awk '{line=tolower($0)} line ~ /"(level|lvl)"[[:space:]]*:[[:space:]]*"(error|crit|critical|fatal)"/ || line ~ /^[[:space:]]*(error[[:space:]]|crit[[:space:]]|panic:|fatal([[:space:]]|:))/' \
        "$1" >> "$RUN/geth-errors.log" || write_failed
}

poll_log() {
    local size count
    [[ -f "$RUN/geth.log" ]] || return 0
    size=$(stat -c %s "$RUN/geth.log") || return 1
    if (( size < offset )); then offset=0; : > "$RUN/.log-pending" || write_failed; fi
    count=$((size - offset)); (( count > 1048576 )) && count=1048576
    (( count > 0 )) || return 0
    { cat "$RUN/.log-pending" && dd if="$RUN/geth.log" iflag=skip_bytes,count_bytes skip="$offset" count="$count" status=none; } > "$RUN/.log-buffer" || write_failed
    offset=$((offset + count))
    if [[ $(tail -c 1 "$RUN/.log-buffer" | od -An -tu1 | tr -d ' ') == 10 ]]; then
        cp "$RUN/.log-buffer" "$RUN/.log-lines" || write_failed
        : > "$RUN/.log-pending" || write_failed
    else
        awk 'NR>1 {print previous} {previous=$0}' "$RUN/.log-buffer" > "$RUN/.log-lines" || write_failed
        tail -n 1 "$RUN/.log-buffer" > "$RUN/.log-pending" || write_failed
    fi
    filter_errors "$RUN/.log-lines"
}

finish_monitor() {
    local result=$? final_size
    trap - EXIT
    if [[ -n $sleep_pid ]]; then kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; fi
    final_size=$(stat -c %s "$RUN/geth.log" 2>/dev/null || echo 0)
    while (( offset < final_size )); do poll_log || break; done
    [[ ! -s "$RUN/.log-pending" ]] || filter_errors "$RUN/.log-pending"
    return "$result"
}
trap finish_monitor EXIT

while (( !stop )) && kill -0 "$PID" 2>/dev/null; do
    NOW=$(date +%s); rpc_ok=0; syncing=null; number=null; hash=''; ready=0
    if curl -fsS --max-time 8 -H 'Content-Type: application/json' "$RPC_URL" \
        --data '[{"jsonrpc":"2.0","id":1,"method":"eth_getHeaderByNumber","params":["latest"]},{"jsonrpc":"2.0","id":2,"method":"eth_syncing","params":[]}]' -o "$RUN/.rpc.json" &&
       jq -e 'type == "array" and (map(select(.id==1))[0].result | (.hash | type=="string") and (.number | test("^0x[0-9a-fA-F]+$"))) and (map(select(.id==2))[0] | has("result") and (.result==false or (.result | type=="object")))' "$RUN/.rpc.json" >/dev/null; then
        rpc_ok=1; recover rpc
        hex=$(jq -r '.[]|select(.id==1)|.result.number' "$RUN/.rpc.json"); number=$((16#${hex#0x}))
        hash=$(jq -r '.[]|select(.id==1)|.result.hash|ascii_downcase' "$RUN/.rpc.json")
        syncing=$(jq '.[]|select(.id==2)|.result != false' "$RUN/.rpc.json")
        [[ $hash == "$TARGET" ]] && target_seen=1
    else
        fault rpc 'Geth RPC unavailable or invalid response'
    fi
    if [[ $hash == "$TARGET" && $syncing == false ]]; then
        (( ready_since > 0 )) || ready_since=$NOW
        (( NOW - ready_since >= READY_SECONDS )) && ready=1
    else
        ready_since=0
    fi
    if poll_alerts && (( rpc_ok )); then last_success=$NOW; fi
    poll_log || fault geth_log 'Could not read Geth log'
    {
        printf 'archive_monitor_timestamp_seconds %s\narchive_monitor_last_success_timestamp_seconds %s\n' "$NOW" "$last_success" || write_failed
        printf 'archive_rpc_reachable %s\narchive_target_reached %s\narchive_sync_ready %s\n' "$rpc_ok" "$target_seen" "$ready" || write_failed
        [[ $syncing == null ]] || { printf 'archive_syncing %s\n' "$([[ $syncing == true ]] && echo 1 || echo 0)" || write_failed; }
        [[ $number == null ]] || { printf 'archive_last_block %s\n' "$number" || write_failed; }
        if (( rpc_ok )); then
            jq -r '.[]|select(.id==2)|.result|select(type=="object") | to_entries[] | select(.key=="stateIndexRemaining" or .key=="trienodeIndexRemaining") | [.key,.value]|@tsv' "$RUN/.rpc.json" |
            while IFS=$'\t' read -r key value; do
                [[ $value =~ ^0x[0-9a-fA-F]+$ ]] || continue
                [[ $key == stateIndexRemaining ]] && metric=archive_state_index_remaining || metric=archive_trienode_index_remaining
                printf '%s %s\n' "$metric" "$((16#${value#0x}))" || exit 1
            done || write_failed
        fi
        if [[ -r /proc/$PID/stat ]]; then
            sed 's/^[0-9]* (.*) //' "/proc/$PID/stat" | awk -v ticks="$ticks" '{printf "archive_geth_cpu_seconds_total %.6f\n",($12+$13)/ticks}' || write_failed
            awk '/^VmRSS:/ {printf "archive_geth_rss_bytes %.0f\n",$2*1024}' "/proc/$PID/status" || write_failed
            awk '/^read_bytes:/ {print "archive_geth_read_bytes_total " $2} /^write_bytes:/ {print "archive_geth_write_bytes_total " $2}' "/proc/$PID/io" || write_failed
        fi
        for disk in ssd hdd; do
            if [[ $disk == ssd ]]; then path=${DATADIR:-}; reserve=${SSD_RESERVE_PERCENT:-20}; else path=${ANCIENT_DIR:-}; reserve=${HDD_RESERVE_PERCENT:-10}; fi
            [[ -n $path ]] || continue
            df -Pk "$path" | awk -v disk="$disk" -v reserve="$reserve" 'NR==2 && $2>0 {printf "archive_disk_available_bytes{disk=\"%s\"} %.0f\narchive_disk_available_ratio{disk=\"%s\"} %.9f\narchive_disk_reserve_ratio{disk=\"%s\"} %.9f\n",disk,$4*1024,disk,$4/$2,disk,reserve/100}' || write_failed
        done
    } > "$TEXTDIR/archive.prom.tmp" && mv "$TEXTDIR/archive.prom.tmp" "$TEXTDIR/archive.prom" || write_failed
    jq -n --argjson time "$NOW" --argjson block "$number" --arg hash "$hash" --arg target "$TARGET" \
        --argjson target_seen "$target_seen" --argjson rpc_ok "$rpc_ok" --argjson syncing "$syncing" --argjson ready "$ready" \
        '{timestamp:$time,last_block:$block,last_hash:$hash,target_hash:$target,target_seen:$target_seen,rpc_reachable:$rpc_ok,syncing:$syncing,sync_ready:$ready}' > "$RUN/status.json.tmp" && mv "$RUN/status.json.tmp" "$RUN/status.json" || write_failed
    if (( ready )) && [[ ! -e "$RUN/sync-complete" ]]; then
        if summary "$RUN" "$START" 'target reached and syncing false for readiness interval'; then
            cp "$RUN/summary.md" "$RUN/sync-summary.md" || write_failed
            date -u +%FT%TZ > "$RUN/sync-complete" || write_failed
            event monitor complete 'Sync readiness reached; Geth and monitoring continue'
        else
            fault summary 'Could not write sync-completion summary'
        fi
    fi
    sleep "$SAMPLE_SECONDS" & sleep_pid=$!
    wait "$sleep_pid" || true
    sleep_pid=''
done
