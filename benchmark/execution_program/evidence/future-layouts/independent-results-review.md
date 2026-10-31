# Future-layout cold pilot: independent receipt review

This review reads the current qualified JSON receipts only; no Julia was run and
no benchmark/source file was changed. Values below exclude the separately
recorded experimental-module loader (about 5.1 s in each worker). The measured
case includes fixture/forcing construction, ordinary preparation, all future
builder/ownership/collection/precompile work and guards, and two execution steps.

## Current small-case result

Seconds; one fresh worker per arm, one observation each:

| Package / arm | Construction | Ordinary preparation | Future phase incl. common guards | First growth | Remaining | Total | Allocated GB |
|---|---:|---:|---:|---:|---:|---:|---:|
| PB ordinary | 2.208340 | 9.269152 | 0.284695 | 3.936312 | 0.221456 | 15.919955 | 4.536464 |
| PB future precompile | 2.362012 | 9.662230 | 4.250360 | 2.282040 | 0.146116 | 18.702759 | 5.114775 |
| PB bounded metadata | 2.280640 | 8.570270 | 0.285689 | 3.592663 | 0.217930 | 14.947191 | 4.358178 |
| PB both | 2.147174 | 8.468685 | 4.236767 | 1.814366 | 0.141203 | 16.808195 | 4.767921 |
| XP ordinary | 11.742003 | 100.654708 | 0.523005 | 15.186415 | 0.147867 | 128.253997 | 14.106019 |
| XP future precompile | 11.601796 | 100.658145 | 11.475036 | 14.370852 | 0.144325 | 138.250153 | 16.303847 |
| XP bounded metadata | 11.447835 | 69.310279 | 0.523884 | 12.234982 | 0.144754 | 93.661733 | 12.824993 |
| XP both | 11.524578 | 69.602005 | 11.045179 | 11.409082 | 0.150377 | 103.731219 | 15.161682 |

PB precompile shifts useful first-growth work upfront: first growth falls
1.654272 s (42.0%), but total rises 2.782804 s (17.5%) and allocations rise
0.578311 GB. Bounded metadata alone has the best current PB total: 0.972763 s
lower (6.1%) with 0.178287 GB fewer allocations. Both reduces first growth
2.121946 s (53.9%) versus ordinary, but total is 0.888240 s higher (5.6%).
Relative to bounded alone, adding future precompile saves 1.778297 s at first
growth while adding 1.861003 s to total (12.5%).

XP precompile saves only 0.815563 s (5.4%) at first growth, adds 10.952031 s to
the future phase, and raises total 9.996155 s (7.8%) and allocations 2.197828 GB.
This is not an overall XP performance improvement. Bounded metadata alone lowers
XP total 34.592264 s (27.0%), ordinary preparation 31.344429 s (31.1%), first
growth 2.951432 s (19.4%), and allocations 1.281025 GB (9.1%). Both lowers total
24.522778 s (19.1%) versus ordinary, but is 10.069486 s (10.8%) slower than
bounded alone and allocates 2.336689 GB more. Adding future precompile to bounded
saves only 0.825901 s at first growth while adding 10.521295 s to the future
phase. Bounded metadata is the useful candidate in this screen; its combination
with the current future catalog is worse than bounded metadata by itself.

## Where the future-phase cost goes

| Future subphase | PB precompile | PB both | XP precompile |
|---|---:|---:|---:|
| Live ownership traversal | 0.140540 | 0.146661 | 0.220788 |
| Independent builder | 0.069746 | 0.068610 | 0.632803 |
| Disposable zero-step preparation | 1.224308 | 1.202926 | 0.766648 |
| Status collection | 0.250205 | 0.276234 | 0.682610 |
| Call/context/signature collection | 1.152208 | 1.148362 | 7.809348 |
| Status Base.precompile requests | 0.015378 | 0.015417 | 0.016800 |
| Call Base.precompile requests | 0.865942 | 0.871422 | 0.528949 |

Inner phase sums exclude some wrapper/guard overhead and are not substituted for
the measured enclosing phase. XP call collection alone allocates 2.070222 GB;
actual call precompile allocates 0.090158 GB. Avoiding only the extra full scene
preparation would save less than 0.8 s in this XP observation and would leave the
dominant collection cost untouched.

## Exact compilation counters and coverage

These are Julia's recorded `compilation_seconds` / `recompilation_seconds`, in
phase order construction, ordinary preparation, future phase, first growth,
remaining execution. They are counters, not disjoint wall-clock partitions;
some construction compilation counters exceed elapsed time, so do not derive
percentages of wall time or sum compilation and recompilation together.

| Package / arm | Compilation counters | Recompilation counters |
|---|---|---|
| PB ordinary | 2.375292124, 9.260050549, 0.283876166, 3.931541376, 0.220249707 | 0.169429875, 0, 0, 0, 0 |
| PB precompile | 2.882655707, 9.651416235, 4.239442046, 2.279434795, 0.145054002 | 0.523462000, 0, 0, 0, 0 |
| PB bounded | 2.453877167, 8.560692098, 0.284904838, 3.586890627, 0.216614250 | 0.175939083, 0, 0, 0, 0 |
| PB both | 2.144478667, 8.459150664, 4.225510135, 1.811671170, 0.140199209 | 0, 0, 0, 0, 0 |
| XP ordinary | 12.016504050, 100.455593301, 0.520335128, 15.151819687, 0.139373959 | 0.760071500, 0, 0, 0, 0 |
| XP precompile | 11.578641614, 100.459954903, 11.405581921, 14.334830371, 0.137545045 | 0.466236167, 0, 0, 0, 0 |
| XP bounded | 12.009302498, 69.117830087, 0.521526169, 12.203552563, 0.137258958 | 1.050142748, 0, 0, 0, 0 |
| XP both | 12.099992793, 69.400248664, 10.979781788, 11.378208978, 0.142248586 | 1.066281959, 0, 0, 0, 0 |

PB accepts 11 requests (2 status constructors + 9 call/kernel/batch/step requests),
collecting 32 unique call signatures, 7 targets/contexts and 4 manual batches.
One additional status request is budget-skipped. Its final full-scene status
match is 6/7 because the lifecycle controller is deliberately excluded; the
correctness companion's newborn match is 6/6.

XP accepts 12 requests (2 status + 10 call signatures), collects 128 call
signatures, 72 targets/contexts and 8 manual batches, skips 37 status constructor
requests and 83 eligible call requests under the actual hint budget, and reports
six partial-newborn initializer layout gaps. Its post-run status matches are
98/98 (newborn companion 52/52). The 15 initially targetless Male/Female
applications are not represented by the declared next Phytomer/Internode/Leaf
archetype, so the call catalog's mandatory-by-category counts are empty. Those
status matches and accepted requests are not evidence that the transient XP
scientific call entry signatures or their MethodInstances/cache were reused.
Original scientific methods remain unwrapped, so the cold records correctly
contain no claimed actual scientific kernel-entry probe coverage.

## Semantic equality and provenance

All four PB timed snapshots share digest
`d06332a1f422af547e67292bb85a9d556d1b7f30a5dcc161454d165c37453187`.
All four XP timed snapshots share digest
`7f7e8c62acad07068ad60587ad908797c8b7990b55923a05b6452f66c7aecf26`.
Digests cover the portable full scientific/history/topology state and copied
scientific RNG fingerprints. Separate outputs=:all correctness companions
passed; timed cases use outputs=:none, seed1, two steps, request budget12/status2.
Canonical Status/reference identities and TaskLocalRNG/task-local seed are guarded
around the future phase in the qualified source.

Each record identifies a distinct fresh Kaimon worker, Julia1.13.1, apple-m3,
14 Julia threads, the same project/manifest hashes and the same package source
aggregates. PSE revision is `f0569286c6f355c9acf85e24fe500a6d769c2c9c`, source
aggregate `5b9c802d03a45600df031befd3c1bb78bd347bc5d471d32f375f8f5d044c4ff7`;
PB `10758c5c7211fc96b625a542ca525cb7856a9ae2`, XP
`5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd`, PlantGeom
`0926bd772721f6b3147ac036b339333edbdc4236`. No source drift was found across
these eight timed records. Loader times are separately 5.029–5.238 s.

The eight matching `*-cpu.json` records are qualified with no other busy Julia
process observed at the monitor's approximately five-second checks; its explicit
scope is other Julia CPU>=5%, excluding the owned process and descendants. This
does not claim an entirely idle operating system or continuous CPU surveillance.
The earlier overlapped PB attempt and its unqualified CPU record are excluded.
Single observations support a screening decision, not a stable percentage claim.

## Next plausible cheap direction

First bound the cold signature collector's value-level interfaces. Its
`_record_target!`, `_record_batch!` and scheduler-record helpers still receive
concrete full target/context/simulation families, despite the outer collector's
barriers. Test one small exact-signature-equivalent collector variant with
bounded inference boundaries, keeping the numerical methods/types unchanged.
The falsifiable target is lower collection compilation/allocation with exactly
the same requested signature set and no kernel/sampling/RNG work. This addresses
the observed XP 7.81 s collection cost directly.

For XP coverage, first add a metadata-only phase descriptor for the transient
targeted calls actually created between organ insertion and initialization. The
existing fully prepared future scene misses these owner/context shapes. Do not
raise the current hint budget indiscriminately: that would mostly precompile
existing complete-scene kernel families before demonstrating new entry coverage.

If repeated use later justifies it, derive the finite catalog once from immutable
definition/schema/environment declarations or record a validated precompile
workload. Reusing/persisting catalog declarations must validate package/source,
schema, numeric/backend/context and world/invalidation assumptions; serializing
mutable simulation state or calling an accepted hint a persistent code cache
would be incorrect. No broad additional benchmark is warranted before the small
collector/signature gate.

## Final XP combined phase detail

The qualified combined XP record has ownership 0.221620 s, independent
builder 0.601201 s, disposable zero-step preparation 0.759295 s, status
collection 0.713713 s, call collection 7.426377 s (2.071745 GB), status
precompile 0.017786 s and call precompile 0.523898 s. Coverage/request counts remain
the same as future-only (12 accepted, 128 unique collected calls, six partial
initializer gaps, 98/98 final status matches). Bounded metadata reduces ordinary
preparation substantially but does not remove the cold collector's dominant
specialization cost. The final workers are PID83505 and PID83806; their CPU
records contain 24 and 30 samples respectively, all without another busy Julia
process. These rows complete the four-arm comparison without changing the source
or benchmark plan.
