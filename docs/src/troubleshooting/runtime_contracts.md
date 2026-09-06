# Inspect A Simulation

When a result is unexpected, first check what ran, where it ran, and which
values it read. The public `Diagnostics` functions return structured rows that
can be displayed as a table. They explain the configured computation; they
do not establish that the scientific equations or parameter values are valid.

| Question | Diagnostic |
|:--|:--|
| Which objects and labels exist? | `Diagnostics.explain_objects(model)` |
| Which models run on them? | `Diagnostics.explain_applications(model)` |
| Where does each input come from? | `Diagnostics.explain_bindings(model)` |
| Which initial values are supplied or missing? | `Diagnostics.explain_initialization(model)` |
| When does each application run? | `Diagnostics.explain_schedule(model)` |
| Which weather or spatial source is sampled? | `Diagnostics.explain_environment_bindings(model)` |
| Which models are called by a controller? | `Diagnostics.explain_calls(model)` |
| Why was an output stream kept? | `Diagnostics.explain_output_retention(simulation)` |

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

Structural changes refresh application targets and their connections **after
the application that changed the structure**. New objects may run applications
still remaining in that time step. They do not retroactively run earlier ones.
Changes made between simulation steps are processed before the next step.

Movement or a geometry update invalidates the affected spatial environment
bindings. Use the public lifecycle functions so the runtime knows that a
refresh is needed. Removing an organ stops its future execution but preserves
its already retained output history. See [Modify plant structure](../journeys/users/structure_changes.md)
for an example that checks both target changes and conservation.
