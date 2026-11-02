# AMAPSim dynamic registry qualification

This is the complete selected original native AMAP architecture/analytic-geometry
scenario, with its original PSE internode projection and `LengthProbe`, plus the
same `QualificationCount` harness in every arm. It is not the coupled
carbon/development/organ-growth ecosystem. No application in the selected N+3
application graph is pruned. An increment is a native developmental coordinate,
not a day.

`ObjectPrograms` admits this graph explicitly. Its runtime owns concrete plant
and internode status arrays, Symbol/tuple ObjectIds, immutable geometry values,
canonical references, sorted destination columns, lifecycle membership and typed
retained samples. Population changes are data, not tuple arity or per-object
methods. The original architecture and property-publisher kernels execute
unchanged. The adapter bridge projects their synchronization boundary onto the
registry's typed lifecycle API. Initializer/call/environment/coupled-controller
protocols are rejected by this admitted lane.

The immutable baseline is `/private/tmp/pse-juliac-large-20261102/sources/AMAPSim`
(revision `86a3215e4a8ec24cb568e238007612e43e9600b5`). The separately owned
`typed-sources/AMAPSim` variant contains only the reproducible inference repairs
in `downstream_amapsim_typing.py` and its patch/complete hash manifest:

- concrete adapter identity containers and static property metadata;
- finite transient apical-plan storage, preserving all 28 values and vector
  references; unknown merge fields are rejected;
- a positional geometry callback specialization barrier;
- literal writes into already-declared state fields;
- finite optional-argument barriers forwarding once to the original Markov
  samplers, without changing their arguments or random-law order.

The variant is **not byte-identical scientific source**. Equations, conditions,
event ordering and random draws remain original. Always report original ordinary
PSE as the primary baseline, inference-typed ordinary PSE as a separate control,
and the same-precompiled-input ordinary control. The typed ordinary arm also
loads the bridge's type-specific projection-ID validation method. Do not attribute typing-repair
or build-time parameter-compilation gains entirely to the registry executor.

The original `branch46.fpa` case has no RNG draws. The additional unchanged
`native_originals/merisier.fpa` profile exercises actual stochastic execution.
`run_checks()` checks original ordinary, inference-typed ordinary and the registry
at initial state and every step, including all mutable native fields, RNG/event
queues, canonical statuses, topology, geometry and output histories. The default
matrix runs branch46 at 1/4 plants, 16 steps, all/none retention, and Merisier at
1 plant, 8 steps with retained outputs. It also checks optional-call forwarding,
plan-vector aliases and rejected unknown plan fields.

Run Julia only through Kaimon. For source preparation (Python only):

```sh
python3 benchmark/juliac_program/downstream_amapsim_typing.py \
  --baseline-root /private/tmp/pse-juliac-large-20261102/sources/AMAPSim \
  --typed-root /private/tmp/pse-juliac-large-20261102/typed-sources/AMAPSim \
  --patch benchmark/juliac_program/downstream_amapsim_adapter_typing.patch \
  --manifest benchmark/juliac_program/downstream_amapsim_typing.json
```

The destination must be fresh. Set `PSE_AMAPSIM_PATH` to the frozen baseline before
loading the checks. The typed bridge never patches that baseline or the loaded
AMAPSim package. Both loaded package and adapter source images are pinned and
checked before construction and after qualification.

`downstream_amapsim_native_project.py` prepares an isolated build project from
the app dependency versions and missing frozen AMAP dependencies. Include
`downstream_amapsim_build.jl` through Kaimon to build safe/generic JuliaC entries;
no verifier override or unsafe trim mode is used. The bundle records its exact
resolved Project/Manifest, patch, source hashes, compile log and executable hash.
`check_native` compares the binary snapshot directly with original ordinary PSE.

`measure_native_case` reports fresh construction/preparation boundaries, JIT
execution for all controls, and AOT setup/execution separately. Timers exclude
process startup and the final snapshot encoding; the final snapshot must still
match original ordinary PSE exactly. Large cases and timing records are retained
separately. The sum of surviving objects' counters is labelled as such; the
registry additionally records actual lifetime counter invocations and removals.

The common-precompiled ordinary factory preserves original plant declaration
order when reconstructing the scene. An initial factory sorted IDs lexically;
its mismatch at population 16 was rejected by the fingerprint gate before a
measurement checkpoint. The correction changes no scientific/native kernel.
Accepted 1/4-plant checkpoints retain their original driver hashes; their graph
order and execution timing boundary are unaffected. All remaining paths were
rewarmed and validated before resuming the serialized timing matrix.

## Measured results

These are **execution-only warm medians**, three measured trials per arm after
warmup, on the same host with other team Julia jobs paused. Construction,
ordinary `run!(...; steps=0)` preparation, registry instantiation, process startup,
source verification and final snapshot I/O are outside these execution timers.
All five arms must match the original ordinary state/RNG/history, and lifetime
calls/registrations/removals are checked in a separate untimed original run.
Times are milliseconds; `none`/`all` specify retained outputs.

| Profile, plants, steps, outputs | Objects | Original ordinary | Inference-typed ordinary | Common-input ordinary | Registry JIT | Safe AOT |
|---|---:|---:|---:|---:|---:|---:|
| branch46, 1, 16, none | 48 | 3.843 | 3.837 | 3.773 | 0.368 | 0.325 |
| branch46, 4, 16, none | 189 | 15.343 | 15.462 | 15.289 | 1.308 | 1.354 |
| branch46, 16, 16, none | 753 | 90.512 | 92.267 | 82.743 | 5.821 | 5.214 |
| merisier, 1, 8, none | 735 | 81.395 | 89.301 | 81.698 | 5.110 | 4.884 |
| merisier, 4, 8, none | 2684 | 722.229 | 656.799 | 699.205 | 21.817 | 22.712 |
| merisier, 16, 2, none | 369 | 39.714 | 40.385 | 40.248 | 2.133 | 1.867 |
| merisier, 4, 8, all | 2684 | 699.987 | 689.152 | 689.670 | 20.042 | 20.529 |

Safe AOT is 11.3–34.1× faster than the original ordinary execution in this bounded
selected scenario, and 11.3–33.6× against the common-precompiled-input ordinary
control. Registry JIT is already close to AOT: these are chiefly registry and
execution-algorithm gains, not a claim that AOT alone provides those factors.
These cases do not qualify the coupled AMAP carbon/light/development ecosystem.

Setup costs are separate. Across these cases, median original construction was
9.5–30.0 ms and ordinary preparation 0.73–2.88 ms; construction includes source
hash verification, FPA parsing and native parameter compilation. The common-input
control's construction was 0.12–0.89 ms plus 0.71–2.82 ms ordinary preparation.
Registry JIT instantiation was 0.054–0.739 ms; AOT instantiation was
0.045–0.823 ms. **Do not combine these differing construction boundaries into a
complete-time speedup.** Full native authoring/preparation occurs at build time;
the safe/generic JuliaC build took 21.485 s compilation, 0.104 s linking and
1.123 s bundling. Raw phase timings and bytes/GC time are retained in the JSON
checkpoints, together with input/source hashes and exact snapshot proofs.

Merisier's 4-plant/8-step case performs 8,462 counter invocations, registers 3,224
internodes and removes 545, ending with 2,679 internodes/2,684 objects. Removed
objects' retained histories and complete native RNG/event/arena state are part
of the exact comparison. No larger-case or cross-host performance extrapolation
is implied.
