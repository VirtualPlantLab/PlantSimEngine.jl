# Adding Roots And Water

Add root objects and gather absorption through a plant-local `Many` selector.
Keep shared carbon and water stocks on the plant, while leaf and root state
remains object-local. Environment precipitation is an environment input; root
creation is an explicit `register_object!` operation with initialized status.

When several plants share one soil object, select it explicitly with a
model-wide `One` selector rather than relying on traversal order.

Keep stocks at the scale that owns conservation. A root model may publish an
absorption rate per root, while the plant model integrates all root rates and
updates one plant water stock. A soil model owns soil water; plants read it
through an explicit model-wide selector. This avoids copying one stock into
every organ and makes duplicate writers visible.

```julia
ModelSpec(
    PlantWaterModel();
    inputs=(
        :root_uptake => Many(
            scale=:Root, within=Subtree(), application=:root_absorption,
            var=:uptake, policy=Integrate(), window=Day(1),
        ),
        :soil_water => One(
            scale=:Soil, within=SceneScope(), application=:soil_water,
            var=:water,
        ),
    ),
)
```

Precipitation, temperature, and radiation remain environment variables, not
ordinary object outputs. Use `Environment(sources=...)` when provider column
names differ from model-facing names. When growth creates a root, initialize
all required root status values before `register_object!`; verify the next
timestep's carrier with `input_value` or `explain_bindings`.
