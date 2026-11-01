# Reusable composite program and JuliaC experiment

This experiment constructs a typed program **directly from `ModelSpec` and model
contracts**, without first constructing or lowering an ordinary `Simulation`.
It is separate from `compiled_model_source`, which explains the ordinary runtime.
It is not yet a production backend or an XPalm release.

## First admitted subset

`app/src/program.jl` prepares an immutable tuple of dependency-ordered regions,
model/schema types, target category and fixed cadence. It stores no model
parameter values, object IDs, memberships, weather or simulation statuses.
Instantiation supplies concrete models and allocates fresh canonical Ref-backed
statuses and row indices. The row loop calls the original `PlantSimEngine.run!`
methods directly. Two applications on an object see the same live references.
Neither source AST concatenation nor runtime `eval` is used.

The first subset has one object category, scalar isbits state, unique local
writers, inferred same-object inputs, one explicit positive fixed cadence and
plain global NamedTuple environment rows. Each `step!` consumes one cadence row.
Calls, temporal policies, output retention, multiple categories, topology,
distributed outputs, environment remapping/commits and context operations are not
implemented. Unsupported declarations are rejected rather than routed through a
second ordinary preparation. Kernels in this experiment do not use context;
unknown context behavior is not inferred automatically from declarations.

`add_object!` adds rows at a host-controlled timestep boundary. It reuses the same
program and existing references, including when the population starts empty.
This demonstrates known-schema vector growth, not kernel-driven PSE lifecycle,
newborn initialization or the full future growth contract.

`app/src/fixture.jl` defines two small generic scientific methods and the ordinary
PSE comparison. Specifications deliberately list the consumer before its producer.
`checks.jl` compares exact final values and retained ordinary biomass samples,
Float32/Float64, changed parameter/weather values, IDs/populations, independent
states, live references and boundary births. Counts and values remain data:
state types are checked across those variations. This does not prove absence of
all internal specializations or JIT for arbitrary downstream models.

## Reproduce through Kaimon

Open a dedicated Kaimon session at the repository root and first inspect its
environment. Evaluate:

```julia
include("benchmark/juliac_program/app/src/program.jl")
include("benchmark/juliac_program/app/src/fixture.jl")
include("benchmark/juliac_program/checks.jl")
ReusableProgramChecks.run_checks()
```

The initial local Julia 1.13.1 run passed **484 assertions**. This is a targeted
prototype qualification, not a full PSE test-suite or scientific qualification.

## Native executable

The autonomous `app/` package defines `@main(args::Vector{String})`. It prepares
its program at package load time. Its fixed CLI schema is:

```text
population steps birth_at newborns id_offset efficiency conversion temperature
```

Counts/IDs are Int, scientific inputs Float64. Weather at step i is
`(T=temperature+i,)`. `birth_at=0` disables births and requires `newborns=0`.
Output is `population,steps,total_carbon,total_biomass`.

Open a **separate Kaimon session at `buildenv/`**, inspect the environment, then
`include("../build.jl")`. This pins JuliaC 0.3.12 outside PSE's dependencies and
uses `trim_mode="safe"`, `cpu_target="generic"`. JuliaC orchestrates its normal
compiler subprocesses from that Kaimon-controlled build. No unsafe trimming or
arbitrary extra entrypoints are used. Each successful build writes its bundle path to `build/latest.txt`. Run
`bin/run-pse-program` within that bundle: it configures bundled artifact lookup
before starting the native `bin/pse_program` image. Distribute the full bundle.

Safe native compilation and five exact ordinary/native comparisons now pass,
including a relocated bundle with an empty external depot and three rejected
invalid CLI cases. Reproduce with `native_checks.jl` after `checks.jl` is loaded.
Initial raw native and timing results are in `results/`. A Julia-level comparison alone does not qualify the native artifact.
The fixed input schema does not itself prove closure of internal call paths.
No zero-JIT or cross-platform binary portability claim is made.

Official tool: [JuliaC](https://github.com/JuliaLang/JuliaC.jl). Next milestones
are safe native execution/parity, charged preparation/runtime comparisons, then
incremental expansion toward calls/publication/lifecycle and original downstream
kernels. Production PSE sources and downstream package sources are unchanged.
