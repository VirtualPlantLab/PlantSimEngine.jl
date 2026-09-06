# Understand Environments

## New concept: declared sampling from global and spatial sources

The first simulation used a weather file as supplied forcing. This page now
makes that contract explicit. A model declares the names it reads from its
model-facing environment:

```@example journey_environments
using PlantSimEngine, Dates, DataFrames
using PlantSimEngine.Examples

(
    degree_days=PlantSimEngine.environment_inputs_(
        ToyDegreeDaysCumulModel(),
    ),
    light=PlantSimEngine.environment_inputs_(Beer(0.6)),
)
```

`ToyDegreeDaysCumulModel` reads `environment.T`; `Beer` reads
`environment.Ri_PAR_f`. These are not status inputs and are not outputs owned
by the target object.

## Global sampling and source names

The source does not need to use the model-facing names. Here a global provider
has `air_temperature` and `incident_par`; `Environment(...; sources=...)`
remaps them for the two model applications.

```@example journey_environments
forcing = (
    air_temperature=20.0,
    incident_par=300.0,
    duration=Day(1),
)

global_model = CompositeModel(
    Object(:plant; scale=:Plant, kind=:plant);
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=One(scale=:Plant),
            environment=Environment(
                provider=:global,
                sources=(T=:air_temperature,),
            ),
        ),
        ModelSpec(
            ToyLAIModel();
            name=:lai,
            on=One(scale=:Plant),
        ),
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=One(scale=:Plant),
            environment=Environment(
                provider=:global,
                sources=(Ri_PAR_f=:incident_par,),
            ),
        ),
    ),
    environment=forcing,
)

validate_environment_inputs(global_model)
global_simulation = run!(global_model)
global_state = final_state(global_simulation)
(TT_cu=global_state.TT_cu, LAI=global_state.LAI, aPPFD=global_state.aPPFD)
```

The environment diagnostic distinguishes the variables seen by each model from
the actual source names:

```@example journey_environments
select(
    DataFrame(Diagnostics.explain_environment_bindings(global_model)),
    :application_id,
    :object_id,
    :required_inputs,
    :source_inputs,
    :handle,
)
```

Global sampling has no spatial handle. The forcing above is intentionally
strict: apart from timeline `duration`, it exposes only the two remapped source
variables. Removing either source makes `validate_environment_inputs` fail
before simulation.

## Spatial sampling

Spatial backends keep the same model-facing declaration. They additionally
compile an opaque handle for each application/object target. The small
`ToySpatialEnvironment` example maps object geometry to either a sunny or
shaded cell:

```@example journey_environments
spatial_environment = ToySpatialEnvironment(
    Dict(
        :sun => (Ri_PAR_f=400.0,),
        :shade => (Ri_PAR_f=100.0,),
    );
    step_seconds=3600.0,
)

spatial_model = CompositeModel(
    Object(
        :sun_leaf;
        scale=:Leaf,
        kind=:leaf,
        geometry=(cell=:sun,),
        status=Status(LAI=2.0),
    ),
    Object(
        :shade_leaf;
        scale=:Leaf,
        kind=:leaf,
        geometry=(cell=:shade,),
        status=Status(LAI=2.0),
    );
    applications=(
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=Many(scale=:Leaf),
            environment=Environment(backend=spatial_environment),
        ),
    ),
)

spatial_simulation = run!(spatial_model)
spatial_states = final_state(spatial_simulation, Many(scale=:Leaf))
Dict(id => state.aPPFD for (id, state) in spatial_states)
```

The one `Many` application retains two distinct compiled handles:

```@example journey_environments
select(
    DataFrame(Diagnostics.explain_environment_bindings(spatial_model)),
    :application_id,
    :object_id,
    :geometry_source,
    :handle,
)
```

The scientific `Beer` kernel is unchanged. It sees only
`environment.Ri_PAR_f`; the backend owns the meaning of each handle. Backend
authors can inspect the implementation of `ToySpatialEnvironment` in the
environment extension reference.

## Page recap

- **You added:** explicit environment declarations, global source remapping,
  and then a spatial backend with object geometry.
- **PlantSimEngine inferred:** global sampling, validation of required source
  names, and one cached spatial handle per application/object target.
- **You keep explicit:** model-facing environment names, scenario source
  remaps, provider/backend choice, and geometry used by a spatial backend.
- **New API names:** `environment_inputs_`, `Environment`,
  `validate_environment_inputs`, `ToySpatialEnvironment`, and
  `Diagnostics.explain_environment_bindings`.
