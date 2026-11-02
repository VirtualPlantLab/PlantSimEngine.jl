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
and the same-precompiled-input ordinary control. Do not attribute typing-repair
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
