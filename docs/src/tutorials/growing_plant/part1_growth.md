# Growing A Plant CompositeModel

Start with [Modify Plant Structure](@ref) for a runnable example of adding and
removing leaves, or changing which object they belong to. This page explains
how to connect those operations to a growth model and a carbon budget.

## Connect organ creation to a resource budget

Store the plant's carbon reserves on the plant object and each leaf's carbon
production on that leaf. `Many(scale=:Leaf, within=Subtree())` lets the plant
collect production from its own leaves. Before adding production to reserves,
check what it represents: a rate, an amount produced during one interval, or
a total accumulated since the start of the simulation. For an accumulated
total, add only the increase since the last update. Adding the full total at
every step would count the same carbon repeatedly.

The growth model's `run!` function then follows this sequence:

1. Read the available carbon and check whether the plant is ready to grow.
2. If so, create the new organ's status with initial area, mass, and any
   other values its models need.
3. Subtract the construction cost once. Add the organ to the simulation with
   a unique identity and the correct parent object.
4. Check the carbon balance: the remaining reserves, the carbon in the new
   organ, and any carbon spent on respiration must add up to the amount
   available before growth.

Use `register_object!` if your model has already created an `Object` with all
its initial values. If you represent the plant with a MultiScaleTreeGraph
(MTG), use `add_organ!` to create its MTG node, status, and simulation object
together. Your growth model must still decide when an organ appears, what it
costs, and how carbon is converted to dry matter.

## Know when a newborn can run

When a model adds, removes, or reparents an organ, PlantSimEngine updates
which objects each model runs on and where their inputs come from
**after that application finishes**. A new leaf can run models scheduled
later in the same timestep. Models that already ran are not repeated.
If the new leaf needs one of those earlier calculations immediately, the
model creating it must declare an `Initializer` and call `run_initializer!`.

If you change the plant structure between `step!` calls, these connections
are updated before the next step. Neither case automatically undoes changes
to the plant's values if something goes wrong.

After creating an organ, check its parent, initial values, first saved result,
and the plant's carbon budget. Use the working example in
[Modify Plant Structure](@ref) to inspect the objects, then continue with
[Adding Roots And Water](@ref) for a small resource-accounting example and
[Debugging Growth And Resource Ordering](@ref) when execution order is unclear.
