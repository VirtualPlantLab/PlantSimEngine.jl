# Growing A Plant CompositeModel

Begin with a plant object and leaf objects whose carbon production is gathered
by a plant application through `Many(scale=:Leaf, within=Subtree())`. A growth
model calls `register_object!` after its carbon or thermal threshold is met.

Structural changes become visible after the current timestep completes. The
new leaf receives status and application targets during refresh and starts on
the following timestep; it cannot consume the resource that created it in the
same kernel call.

Build the initial registry explicitly so ownership remains visible:

```julia
model = CompositeModel(
    Object(:plant; scale=:Plant, status=Status(carbon=0.0)),
    Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(area=1.0));
    applications=(leaf_application, plant_balance, growth_application),
    environment=weather,
)
```

The plant balance gathers leaf production with
`Many(scale=:Leaf, within=Subtree())`. The growth kernel obtains the live model
with `runtime_model(extra)`, checks its carbon and thermal thresholds, creates
a fully initialized `Object`, and calls `register_object!`. It should deduct
the construction cost exactly once before registration.

After each step, assert both biology and structure: remaining plant carbon,
the number of leaf objects, each new leaf's parent, and accepted historical
outputs. `explain_applications` should show that the new leaf is absent
during its creation step and present after the between-step refresh.
