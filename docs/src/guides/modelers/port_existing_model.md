# Port An Existing Model

Start with a one-step scientific function and separate four concerns: immutable
parameters, object state, environment forcing, and produced values. Keep the
arithmetic generic; a model should not convert compatible values to `Float64`.

```@example port-existing-model
using Dates
using PlantSimEngine

PlantSimEngine.@process "docs_lai_growth" verbose = false

struct DocsLAIGrowth{T} <: AbstractDocs_Lai_GrowthModel
    rate::T
end
PlantSimEngine.inputs_(::DocsLAIGrowth) = (lai=0.0,)
PlantSimEngine.outputs_(::DocsLAIGrowth) = (lai_next=0.0,)
PlantSimEngine.meteo_inputs_(::DocsLAIGrowth) = (T=0.0,)
function PlantSimEngine.run!(m::DocsLAIGrowth, status, meteo, constants, extra)
    status.lai_next = status.lai + m.rate * meteo.T
end

model = CompositeModel(
    DocsLAIGrowth(0.02);
    status=(lai=1.0,),
    environment=(T=10.0, duration=Day(1)),
)
simulation = run!(model)
@assert only(model_objects(model)).status.lai_next == 1.2
```

Test the scientific function first, then the kernel directly with a `Status`,
and finally the same model through a model. These three levels separate a
scientific error from a model-contract error and a scenario-binding error.
`explain_initialization(model)` should show `lai` as supplied, `T` as
environment-bound, and `lai_next` as generated.

The concise constructor lowers to the ordinary CompositeModel compiler; it is not a
separate runtime. Move to explicit `Object` and `ModelSpec` construction only
when the scenario needs multiple objects, selectors, or named applications.
