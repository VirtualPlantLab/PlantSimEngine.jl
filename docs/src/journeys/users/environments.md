# Understand Environments

## Give models weather and light

An **environment** supplies values such as air temperature and incident light.
Here you will first use weather data whose column names differ from the names
your models expect. Then you will give a sunny canopy more light than a shaded
one. The models and weather values are chosen to explain these operations.

## Match weather names to model inputs

Suppose your weather data use the names `air_temperature` and `incident_par`,
but your models expect `T` and `Ri_PAR_f`. Use `sources` in `Environment(...)`
to say which weather variable supplies each model input. `provider=:global`
means that the weather values do not depend on the object's position.

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
`environment.Ri_PAR_f`. These values come from the weather data. They are
separate from values stored on the canopy, such as its LAI.

The table below shows the names each model expects (`required_inputs`) and the
names it reads from the weather data (`source_inputs`):

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

The `handle` column is empty because neither model needs a spatial location
to read this weather. The example supplies only `duration` and the two weather
variables. If either weather variable is missing,
`validate_environment_inputs` reports it before you run the simulation.

## Give each canopy its own light

When weather or light varies across space, an **environment backend** supplies
the values at each object's location. The models still read the same input
names. The small `ToySpatialEnvironment` example below stores a light value in
each of two cells, named `:sun` and `:shade`. Each canopy's `geometry` says
which cell to use. These light values are supplied directly; this example does
not calculate how light travels through a canopy.

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

The table below lets you check that each canopy reads from its intended cell.
PlantSimEngine stores this location in a value called a **handle**, so it does
not need to find the cell again at every step:

```@example journey_environments
select(
    DataFrame(Diagnostics.explain_environment_bindings(spatial_model)),
    :application_id,
    :object_id,
    :geometry_source,
    :handle,
)
```

The `Beer` equation is unchanged. It reads `environment.Ri_PAR_f` in both
examples; the environment supplies the correct value. To provide your own
spatial data, see [Environment Backend Extensions](@ref).
