# Final preparation-scaling cold audit

Offline independent audit: **five qualified timing records and six intended scientific cases pass**. The optional XP graph-only case remains strictly excluded. No Julia or service calls by this auditor.

| Package / arm | PID | Model first use (s) | Inclusive first use (s) | PSE preparation (s) | Timing |
|---|---:|---:|---:|---:|---|
| pb / ordinary_a | 1473 | 13.478 | 20.962 | 10.921 | qualified |
| pb / typed_graph | 2323 | 12.676 | 20.279 | 10.135 | qualified |
| pb / bounded_graph | 2622 | 12.627 | 20.408 | 10.017 | qualified |
| xp / ordinary_a | 4902 | 130.016 | 139.135 | 104.024 | qualified |
| xp / typed_graph | 4263 | 66.668 | 75.733 | 43.863 | qualified |
| xp / bounded_graph | 7114 | 67.652 | 77.538 | 43.908 | excluded |

Every qualified artifact binds exact raw/CPU/reproduction/completion bytes, healthy whole-RPC sampling, a positive new private worker, environment/identity absence proof, verified worker shutdown and matching frozen source image. The six intended workers have distinct PIDs; all224 guarded source files and all recorded PSE/PB/XP/PlantGeom source bytes/hashes match. Per-package full state/history/types/RNG/work/config observations match, as do each first-use/fresh-warm pair. No scientific kernel/storage backend changes are credited.

XP ordinary→combined is130.016→66.668s model-first-use (ratio0.5128), or139.135→75.733s inclusive (0.5443). PSE preparation is104.024→43.863s, the main observed difference. PB ordinary→combined is13.478→12.676s model-first-use (0.9405),20.962→20.279s inclusive (0.9674). These are single descriptive pilot pairs, not repeatable medians.

The final XP controller prewarm executes only `sleep(31); :kaimon_broker_ready` and completed-job polling before scientific startup. Receipts prove completion before the scientific request; Main and loaded-module package absence guards are rerun before the clock and pre-import flags are false. This warms Kaimon brokerage, not PSE models or IR. Common helper/package-union imports and XP registration/weather work remain inside the inclusive scientific-startup clock. Kaimon controller startup, identity, prewarm and quiet waits are separately recorded outside it.

The XP graph-only run passed scientific/parity/source checks, but the whole-RPC CPU record observed the broker at5.8%. Its relocation hash and worker shutdown proof validate. The original strict gate is retained: no timing ratio, interval rescue, retiming or additional rerun is credited. Earlier contaminated/failed attempts are not replications.

Compilation counters remain Julia-reported diagnostics: some exceed their phase wall time, so do not subtract them to claim an exclusive framework/science split. Fresh-warm companions are newly constructed independent models but are not a repeated warm benchmark. No qualified XP graph-only comparison establishes a cold typed-only increment; the cold result supports the combined candidate versus ordinary execution.

Normal disk and package caches were retained. No peak-RSS, million-organ, optional-package or full-suite claim follows. Detailed hash/ownership/prewarm proofs are in the companion JSON.
