# Collecting And Plotting Outputs

Run a scene to obtain `SceneSimulation`, then call `collect_outputs(sim)` for
ordinary analysis. Rows identify application, object, variable, timestep/time,
and value, so repeated processes cannot overwrite one another. Convert the rows
to a `DataFrame`, filter by application/object/variable, group, and plot.

Runs default to `outputs=:none`. Use `outputs=:all` only when complete stream
history is intentional; selected requests are the memory-safe choice for large
scenes. Raw rows have the stable columns `timestep`, `time`, `application_id`,
`object_id`, `variable`, and `value`. Requested/resampled rows additionally
identify `scale` and `process`. A temporal request emits `missing` when its
policy cannot produce a value for a scheduled output time.
`time` is expressed in scene base-step coordinates; application clock metadata
is reported by `explain_schedule(simulation)`. Values retain their concrete
types, so unit-bearing model outputs remain unit-bearing in collected rows.

`OutputRequest` controls requested retention or resampling. Dependency streams
may also be retained for runtime correctness. Use
`explain_output_retention(sim)` to see why each stream exists. Removed objects
retain accepted historical rows.

```@example collect-output
using Dates
using DataFrames
using PlantSimEngine

PlantSimEngine.@process "docs_output_counter" verbose = false
struct DocsOutputCounter <: AbstractDocs_Output_CounterModel end
PlantSimEngine.inputs_(::DocsOutputCounter) = NamedTuple()
PlantSimEngine.outputs_(::DocsOutputCounter) = (value=0,)
PlantSimEngine.run!(::DocsOutputCounter, models, status, meteo, constants, extra) =
    (status.value += 1)

scene = Scene(DocsOutputCounter(); environment=(duration=Hour(1),))
simulation = run!(
    scene;
    steps=3,
    outputs=OutputRequest(
        One(scale=:Scene),
        :value;
        name=:counter,
        application=:docs_output_counter,
    ),
)
rows = collect_outputs(simulation, :counter; sink=nothing)
table = DataFrame(rows)
@assert table.value == [1, 2, 3]
table
```

For plotting, filter the table first and map `time` to the horizontal axis and
`value` to the vertical axis. Group by `application_id` and `object_id` before
drawing lines; grouping by variable alone can accidentally connect different
objects. CairoMakie and other plotting packages consume the resulting columns
without any PlantSimEngine-specific adapter.
