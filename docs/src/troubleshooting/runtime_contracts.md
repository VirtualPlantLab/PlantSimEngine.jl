# Inspect A Simulation

When a result is unexpected, first check what ran, where it ran, and which
values it read. The `Diagnostics` functions return information you can display
as a table. Use them to check how the simulation is configured. Check the
scientific equations and parameter values separately.

| Question | Diagnostic |
|:--|:--|
| Which objects and labels exist? | `Diagnostics.explain_objects(model)` |
| Which models run on them? | `Diagnostics.explain_applications(model)` |
| Where does each input come from? | `Diagnostics.explain_bindings(model)` |
| Which initial values are supplied or missing? | `Diagnostics.explain_initialization(model)` |
| When does each application run? | `Diagnostics.explain_schedule(model)` |
| Which weather or spatial source is sampled? | `Diagnostics.explain_environment_bindings(model)` |
| Which models are called by a controller? | `Diagnostics.explain_calls(model)` |
| Why were earlier values of an output kept? | `Diagnostics.explain_output_retention(simulation)` |

## Inspect a small working example

Here leaf surface depends on supplied carbon biomass. Check its input source
before running a larger structure:

```@example inspect_simulation
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

model = CompositeModel(ToyLeafSurfaceModel(0.02);
    status=(carbon_biomass=50.0,), id=:leaf, scale=:Leaf)
DataFrame([
    (variable=row.variable, role=row.role, disposition=row.disposition)
    for row in Diagnostics.explain_initialization(model)
])
```

```@example inspect_simulation
simulation = run!(model; outputs=:all)
@assert final_state(simulation).surface ≈ 1.0 # hide
DataFrame(Diagnostics.explain_output_retention(simulation))
```

If model construction fails, use the error's object and application names to
correct the configuration first. A diagnostic cannot inspect a model that was
never constructed.

## After growth or movement

After adding or removing organs, PlantSimEngine updates which objects each
model runs on and where its inputs come from. This happens **after the
application that changed the structure finishes**. New organs may run models
scheduled later in the same time step. Models that already ran are not
repeated. If you change the structure between steps, these connections are
updated before the next step.

If you move an organ or change its geometry, PlantSimEngine needs to find its
new location in the spatial environment. Use functions such as `move_object!`
and `update_geometry!` so it knows to update this connection. Removing an
organ stops its future calculations and keeps results that were already
saved. See [Modify plant structure](../journeys/users/structure_changes.md)
for an example that checks the affected objects and their carbon balance.
