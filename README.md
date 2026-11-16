# geth-archive

Run one mainnet path-based archive node to a fixed block hash, collect metrics, record anomalies, and write a sync summary. The active workflow uses Bash and standard metrics services; historical-data validation is deferred.

## Start

Use Ubuntu with Git, Make, a C compiler, Go (as required by Geth's `go.mod`), Bash, curl, jq, and Docker with Compose v2. Docker must be accessible to the current user. Use tmux for a long sync.

From this repository's root:

```sh
git clone https://github.com/ethereum/go-ethereum.git geth
make -C geth geth
cp config.env.example config.env
```

Set four values in `config.env`:

- `DATADIR`: An existing directory on the SSD for the active database.
- `ANCIENT_DIR`: An existing directory on the HDD for ancient data.
- `RUN_ROOT`: A directory on the SSD for logs, reports, and the metrics database.
- `TARGET_HASH`: A trusted mainnet block hash (`0x` plus 64 hex digits), not a block number.

Mount both disks first and check the paths with `findmnt -T <path>`. The first run requires fresh data directories. Running the same command again with the same configuration resumes the database.

```sh
./run.sh --dry-run   # Check configuration and print the Geth command.
./run.sh             # Start metrics, Geth, and monitoring; keep this in tmux.
```

The script prints the run directory. Geth output is in `geth.log`; monitoring output is in `monitor.log`. Press Ctrl-C for a graceful shutdown and a final `summary.md`.

## Geth settings

The script checks that the configured binary supports every flag before starting.

| Setting | Value / purpose |
| --- | --- |
| Sync | `--state.scheme path --syncmode full --gcmode archive --synctarget HASH` |
| History | `--history.state 0 --history.trienode 0`; retain both histories and their indexes |
| Trienode checkpoint | `--history.trienode.full-value-checkpoint 8` |
| Other storage | `--history.chain all --history.transactions 2350000 --history.logs.disable --cache.preimages` |
| Cache | `--cache 4096`, a starting value for 24 GiB RAM |
| Optional memory limit | Set `MEMORY_LIMIT_MB=12288` to pass `--memorylimit 12288`; omit or leave empty to use runtime defaults |
| HTTP RPC | `127.0.0.1:8545`, eth/net/web3 only |
| Metrics | `127.0.0.1:6060`, enabled with `--metrics` |

By default, no `--memorylimit` flag is passed. An existing `GOMEMLIMIT` environment variable still applies. The optional Go memory limit is a soft limit, not a process RSS cap; `--cache` is not a total process memory limit either. Chain data is retained; the target bounds how far the node syncs. Existing pruned or snap-synced databases do not regain missing archive history by changing flags.

This is Geth's `synctarget` development mode. Do not connect a consensus client at the same time. Its safe/finalized markers are synthetic. Historical blocks still need to be available from peers. `--exitwhensynced` is intentionally omitted so indexing can settle.

## Metrics and anomalies

`run.sh` starts two containers:

- **Prometheus** scrapes every exposed Geth metric and all enabled node_exporter metrics every 15 seconds. Data is stored under `RUN_ROOT/metrics/data`, with 30-day and 20 GB retention limits.
- **node_exporter** provides host CPU, memory, swap, filesystem, and disk I/O metrics. The shell monitor adds Geth RSS, physical process I/O, disk free space, and RPC sync status through its textfile collector.

Prometheus is available at `http://127.0.0.1:9090`; its Alerts page shows active conditions. From another machine, use an SSH tunnel:

```sh
ssh -L 9090:127.0.0.1:9090 user@server
```

`alerts.jsonl` records alert transitions and monitoring failures. `geth-errors.log` records Geth ERROR/CRIT/fatal/panic output. Rules cover missing scrapes, a stale monitor, low memory/free disk space, sustained CPU or I/O pressure, swap activity, and stalled sync progress. High CPU is an observation to investigate, not proof of a fault. Thresholds are in `alerts.yml`.

Only Prometheus should scrape Geth metrics. Reading another metrics endpoint consumes ResettingTimer samples. Those timers expose per-scrape counts and quantiles, not cumulative operation time; do not apply `rate()` or `increase()` to their `_count` series. Geth's `system_disk_*bytes` metrics are logical I/O; physical I/O is recorded separately.

## Sync summary

When the latest executed block matches `TARGET_HASH` and `eth_syncing` remains false for six minutes, the monitor writes `sync-summary.md`. This allows time for the history indexers to finish their initial work. The node and monitoring keep running afterward.

The summary includes observed duration, sync status, CPU and memory usage, disk space, physical I/O, available history-size metrics, and recorded anomalies. Missing metrics are reported as unavailable. Stopping the run also writes `summary.md`, including when the target has not been reached.

This reports sync and indexing progress. Historical data correctness checks and request-serving validation are deferred. A single run cannot establish a precise CPU or time overhead for enabling a feature.

Metrics remain available after Geth stops. To stop the monitoring containers while retaining their data:

```sh
docker compose -p geth-archive down
```

Do not run a second experiment on the same host ports. This setup records alerts; it does not automatically repair the database or restart Geth. If the shell monitor exits unexpectedly, the runner stops Geth gracefully.

The previous toolkit is preserved in `legacy/` as a local backup and is not used by this workflow.

## License

GPL-3.0-or-later; see `COPYING`.
