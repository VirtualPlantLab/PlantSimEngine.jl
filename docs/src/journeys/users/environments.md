# Understand Environments

## New concept: declared sampling from global and spatial sources

Use weather whose column names differ from those expected by the models,
then give two canopies different radiation supplies. An **environment**
provides external values such as air temperature and incident light.
This page uses teaching models and illustrative forcing.

## Global sampling and source names

The source does not need to use the model-facing names. Here a global provider
has `air_temperature` and `incident_par`; `Environment(...; sources=...)`
remaps them for the two model applications.

```@example journey_environments
using PlantSimEngine, Dates, DataFrames
using PlantSimEngine.Examples

forcing = (
    air_temperature=20.0,
    incident_par=300.0,
    duration=Day(1),
)

global_model = CompositeModel(
    Object(:canopy; scale=:Canopy, kind=:canopy);
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=One(scale=:Canopy),
            environment=Environment(
                provider=:global,
                sources=(T=:air_temperature,),
            ),
        ),
        ModelSpec(
            ToyLAIModel();
            name=:lai,
            on=One(scale=:Canopy),
        ),
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=One(scale=:Canopy),
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

`T` and `air_temperature` are in °C. `Ri_PAR_f` and `incident_par` are
mean PAR fluxes in W m⁻² of ground; changing a source name does not convert
its units. `aPPFD` is absorbed PAR in μmol m⁻² of ground s⁻¹.

## Inspect the input names

A model declares which external values it needs. You can inspect those names
without changing the model:

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
associate each object with its source location. The small
`ToySpatialEnvironment` example maps a cell label to either a sunny or shaded
canopy. This label-based fixture demonstrates sampling; it does not compute
light transport from a geometric scene:

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
        :sun_canopy;
        scale=:Canopy,
        kind=:canopy,
        geometry=(cell=:sun,),
        status=Status(LAI=2.0),
    ),
    Object(
        :shade_canopy;
        scale=:Canopy,
        kind=:canopy,
        geometry=(cell=:shade,),
        status=Status(LAI=2.0),
    );
    applications=(
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=Many(scale=:Canopy),
            environment=Environment(backend=spatial_environment),
        ),
    ),
)

spatial_simulation = run!(spatial_model)
spatial_states = final_state(spatial_simulation, Many(scale=:Canopy))
Dict(id => state.aPPFD for (id, state) in spatial_states)
```

Both canopies have LAI = 2 m² m⁻². The sunny canopy receives four times the
incident PAR of the shaded canopy, so its absorbed PAR is also four times
as large. Both results use ground area, not individual leaf area.

The optional diagnostic below shows two different cached source locations
(called handles), one for each canopy:

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
