# Untouched-source MAESPA ordinary baselines

Eight complete original `two_species.jl` configurations, with adjacent equal-area tiling for four copies. No MAESPA scientific source or backend was changed. Julia 1.13.1, two threads, PlantMeteo 0.9.1; fresh states, one excluded warmup and three measured samples per configuration. Other team Julia jobs were paused during accepted timing.

Construction, ordinary `run!(steps=0)` preparation and complete `continue!` execution are separate medians below (milliseconds). Source checks, canonical snapshots, record formatting and hashing are outside timers. Cold four-tile preparation (111 s) and first scientific-step compilation (140 s) were excluded.

| Tiles | Steps / first slot | Outputs | Objects / apps | Construction | Preparation | Execution | Records |
|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | 24 / 13 | all | 27 / 100 | 4.524 | 82.115 | 91.163 | 28202 |
| 1 | 24 / 13 | none | 27 / 100 | 4.163 | 69.284 | 85.405 | 2153 |
| 1 | 96 / 1 | all | 27 / 100 | 4.382 | 85.776 | 272.544 | 90874 |
| 1 | 96 / 1 | none | 27 / 100 | 4.410 | 69.524 | 248.925 | 2157 |
| 4 | 24 / 13 | all | 99 / 292 | 10.514 | 473.729 | 415.857 | 91244 |
| 4 | 24 / 13 | none | 99 / 292 | 9.919 | 445.653 | 391.654 | 7205 |
| 4 | 96 / 1 | all | 99 / 292 | 10.317 | 502.539 | 1155.631 | 283780 |
| 4 | 96 / 1 | none | 99 / 292 | 10.971 | 456.067 | 1106.623 | 7221 |

The original scientific source aggregate is `21b3dd24a9a872cbf2a3254016cab687bc9397a1d97edb97b24f1b9a3eebf50f`. Per-case JSON retains source/config/encoder/adapter hashes, all raw timing samples, canonical full-snapshot hashes, sorted encoded-record hashes/counts and actual work witnesses.

The refreshed observation format is **F/T/S/H/O/E**. Each retained stream key has an H record even when its sample sequence is empty. Fresh-run A/A records were identical for every case. These are original baseline results; cross-arm native/typed verification is a separate qualification step. Target/meteorology RNGs belong to construction, and this fixed AllTargetTrees/forcing scenario does not establish runtime stochastic coverage.

Full plain comparison records are deliberately outside Git at `/private/tmp/pse-juliac-large-20261102/maespa-original-records/final/`. Their file hashes and the comparison hash (`SHA256(join(sorted_records, "\n"))`, excluding a final newline) are both recorded. Duplicated warmup text/JSON is archived in the same temporary root. No large raw output file is committed.

The loaned APP Kaimon session was `388bdfdf`. The H formatter was refreshed from the current adapter before qualification. One initial evidence-save attempt failed because a relative include filename resolved an encoder path against app/; no result from that attempt was accepted. Final orchestration was loaded by absolute path and all eight measured checkpoints completed.
