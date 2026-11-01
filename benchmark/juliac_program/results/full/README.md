# Complete XPalm graph: carbon and reproductive execution

This case uses all 61 original `architecture=false` XPalm applications from
`XPalm.model_applications`. It includes carbon assimilation, maintenance and
growth respiration, organ demand, allocation and reserves, vegetative growth,
sex determination, abortion, male/female emission and reproductive processes.
XPalm is pinned to `5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd`.
Scientific kernels and downstream sources are unchanged.

The full layout derives routes directly from the original ModelSpec tuple. It
has 50 scheduled applications, 11 manual call targets and ten category cohorts.
It uses per-application status views, live reference-backed Many inputs,
distributed destination columns, producer-specific PreviousTimeStep histories,
and explicitly ordered Updates writers. Temporal history is independent of
user-facing output retention. Mutable model RNGs are private to each simulation
and shared by that application's objects in ascending ObjectId order.

`FullXPalmFixture.authoring` imports the original Palm topology and status
policy into typed topology descriptors and scientific input records. The native
entry reconstructs genuine empty-attribute MTG nodes; all scientific status
belongs to the typed registry. Palm construction, parameter-file loading,
ModelSpec construction and program preparation happen at build time.

## Reproduce

Use a dedicated Kaimon session at `benchmark/juliac_program/app`:

```julia
include("../full_xpalm_checks.jl")
FullXPalmChecks.run_checks()
```

The driver compares every canonical scientific field, node ID, parent, MTG link
and index after every timestep. It also compares every retained output key and
value, future RNG draws, output-free temporal execution and simulation ownership.
The carbon case uses default phenology. The seeded reproductive case shortens
original phenology durations to exercise original emission kernels in a short
run; those parameter changes are test inputs, not calibration.

Build from a Kaimon session at `benchmark/juliac_program/buildenv` with
`include("../build.jl")`. The entry format is:

```text
/path/to/bundle/bin/run-pse-program full days phyllochron_rate reproductive
/path/to/bundle/bin/run-pse-program full 3 0.05 false
/path/to/bundle/bin/run-pse-program full 12 0.3 true
```

The machine-readable output contains `F` metadata, `T` topology for every
object including empty Stem status, `S` canonical variables, `O` retained output
samples and `R` four future UInt64 draws from copies of each scientific RNG.
Arrays use semicolon-delimited brackets. No generic display or checksum hides
individual fields. The native verification driver is:

```julia
include("../full_xpalm_native_checks.jl")
FullXPalmNativeChecks.run_checks()
```

## Qualification boundaries

The complete carbon case passes **4,075 Julia-level assertions** over three days,
with 8 initial objects, 11 final objects and 422 retained samples (`carbon.json`).
Every scientific field and topology is compared after every step, as are all
output keys/values and RNG state. The original PSE reproductive reference has
also executed for 12 days, creating 7 Male and 3 Female objects (54 total;
`reproductive-reference.json`). Reproductive typed-runtime and native executable
qualification are still in progress. A successful build alone does not establish
native execution parity.

This is the complete pinned `architecture=false` application graph for one
original Palm and the specified forcing/parameter cases. Architecture rendering,
arbitrary MTG attribute stores or schemas, multirate policies beyond this daily
case, spatial environments, evaluate/accept calls, topology removal/reparenting
and heterogeneous overrides are outside this entry. These checks are execution
parity evidence, not a scientific calibration, performance or zero-JIT claim.
