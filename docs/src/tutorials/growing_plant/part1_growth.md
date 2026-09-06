# Growing A Plant CompositeModel

Start with [Modify Plant Structure](@ref) for a runnable example of adding,
reparenting, and removing leaves. This page explains the extra decisions needed
when a biological growth model owns those operations.

## Connect organ creation to a resource budget

Keep the plant carbon stock on the plant object and leaf production on the
leaves. The plant balance gathers only descendant production with
`Many(scale=:Leaf, within=Subtree())`. State whether production is a rate,
an interval amount, or a cumulative quantity before connecting it to a stock.
An accumulated source must be differenced or accounted for once; adding its
whole value repeatedly creates carbon.

A growth kernel then follows this sequence:

1. Read the plant's available carbon and the developmental condition.
2. If growth is permitted, construct the new organ's status with explicit
   initial area, mass, and other required values.
3. Charge the construction cost once and register the organ with its stable
   identity and correct parent.
4. Check that remaining reserves plus constructed material reproduce the
   pre-growth budget, including any explicitly modelled respiration cost.

Use `register_object!` when the caller has constructed a fully initialized
`Object`. For an MTG-backed model, use `add_organ!` so the MTG node, status,
and runtime object are created together. Neither operation chooses an
organogenesis hypothesis, construction cost, or carbon-to-dry-matter conversion
for you.

## Know when a newborn can run

When a kernel changes topology, PlantSimEngine refreshes targets and bindings
**after that application**. A new leaf can run applications that remain later
in the same timestep. An application that already completed is not rerun.
If a newborn needs that application's initial calculation immediately, its
creator must declare an `Initializer` and call `run_initializer!` explicitly.

When the caller changes topology between `step!` calls, the refresh happens
before the next step. These are two different entry points to the same
lifecycle mechanism; neither implies a rollback of biological state.

Check the organ's parent, required initial values, first retained sample, and
plant carbon budget after creation. Use the working example in
[Modify Plant Structure](@ref) to inspect the registry, then continue with
[Adding Roots And Water](@ref) for a small resource-accounting example and
[Debugging Growth And Resource Ordering](@ref) when execution order is unclear.
