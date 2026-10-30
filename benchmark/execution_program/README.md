# Execution program investigation

This draft investigates the remaining gap between PlantSimEngine execution and the same scientific kernels in plain Julia. It keeps opt-in execution experiments and conservative ordinary fallbacks while comparing each hypothesis independently.

The next baseline integrates the reviewed changes from PRs #240, #241 and #242. PR #243 remains separate because its Julia 1.13 CI jobs timed out. Fresh results will record exact source heads and compare against the improved baseline; percentages from other packages are not added together.

Work in progress: shared immutable call-program structure, promotion of validated newborn input bindings, and a no-framework numerical-loop reference. Selective fusion, common-cadence loops and proven independent organ batches follow the measured gap. Exception/reentry/publication/lifecycle semantics remain correctness gates.

Historical call/growth evidence is frozen in [evidence/historical-call-growth](evidence/historical-call-growth/index.json). The gzip records preserve the complete original JSON, including all phase counters, scientific snapshots, digests and source provenance. They are not measurements of the new baseline. Earlier local raw archives remain unchanged.

All Julia processes and checks use Kaimon. Optional downstream packages stay outside the default benchmark project. Start each new candidate with small correctness checks and warm samples; record cold Julia compilation separately from warm preparation and runtime.
