# Authoring and diagnostics

Read this reference when discovering processes/models, reviewing a model
boundary, comparing alternatives, validating a scenario, or investigating a
compiler/runtime failure.

## Use the neutral authoring API first

`PlantSimEngine.Authoring` is the public machine-readable entry point:

```julia
using PlantSimEngine
using PlantSimEngine.Authoring

available_processes()
available_models(:photosynthesis)
describe_model(model_or_type)
model_interface(model_or_type)
compare_models(first_model, second_model)
validate_model(model; strict=true)
validate_scenario(composite; strict=false)
```

Do not parse `show`, generated documentation, exception prose, or compiler
fields when one of these functions represents the information directly.

An instance descriptor is exact for its parameter values and declared schemas.
A type-only descriptor may be best effort when the type cannot be constructed
without scientific parameters. Preserve provenance/reliability markers in
reports and do not present inferred values as exact.

## Process identity versus replacement compatibility

Use `compare_models(a, b)` before `Override` or another direct replacement.
Interpret the report in this order:

1. Are both values concrete PlantSimEngine models?
2. Do they implement the same process?
3. Do status inputs and outputs match?
4. Do environment inputs and outputs match?
5. Do all `VariableContract`s match?
6. Do dependencies, hard calls, initializers, time/output traits, and routing
   remain compatible?
7. Does the report mark the pair as a direct replacement, or list bindings and
   scenario policies that must change?

“Same process, incompatible interface” is a valid scientific design. It means
the scenario must be adapted; it is not a reason to add unused ports or hide
defaults merely to force interchangeability.

The structured result exposes `same_process`, `override_compatible`,
`requires_binding_changes`, `requires_reconfiguration`, and a `compatibility`
classification: `:direct_override`, `:same_process_requires_reconfiguration`,
or `:different_process`. Inspect every entry in `differences`; its `path`,
`kind`, `left`, `right`, `affects_override`, and `affects_bindings` fields
explain whether the scenario needs new value wiring, another configuration
change, or both. Preserve the report's `schema_version` when serializing it
with `to_dict` or `to_json`.

## Validate partial work early

`validate_model` checks the model-level declarations. Use strict mode only
when the package or task has enough scientific metadata to satisfy it without
inventing values.

`validate_scenario` should be used before `run!`. A scenario under construction
may return a partial report with structured diagnostics rather than a single
exception. Consume diagnostic codes, severity, application/object identities,
variables, and suggestions. Keep the report's `schema_version` when
serializing it.

Structural validation is exhaustive only for declared/compiled structure.
Execution probes may depend on data values and branch paths; do not claim that
one probe validates every scientific branch.

## Explain the compiled scenario

Use the narrowest relevant diagnostic:

| Question | Public diagnostic |
| --- | --- |
| Why can/cannot the scenario initialize? | `Diagnostics.explain_initialization` |
| Which application runs on which object? | `Diagnostics.explain_applications` |
| Where does an input value come from? | `Diagnostics.explain_bindings` |
| What carrier/value is used now? | `Diagnostics.input_carrier`, `Diagnostics.input_value` |
| Which hard-call targets were resolved? | `Diagnostics.explain_calls` |
| Why is execution ordered this way? | `Diagnostics.explain_schedule` |
| Who owns or updates a variable? | `Diagnostics.explain_writers` |
| How are objects execution-batched? | `Diagnostics.explain_execution_plan` |
| Which environment source/handle is compiled? | `Diagnostics.explain_environment_bindings` |
| Which backend does a completed simulation use? | `Diagnostics.explain_environment` |
| Why is an output retained? | `Diagnostics.explain_output_retention` |
| Which runtime phase costs time? | `Diagnostics.explain_runtime_performance` |

Names may have more specific overloads; inspect methods on the verified loaded
version rather than guessing arguments.

Use runtime performance explanations only after opting in with
`run!(model; performance=true)`. Instrumentation adds work, so benchmark normal
execution separately with `performance=false`.

## Read the resolved execution as Julia

When the relationships are easier to review as source than as diagnostic rows,
generate the public readable view:

```julia
source = Authoring.compiled_model_source(scenario)
```

This source shows the resolved application order, targets, bindings, calls,
environment sampling, and invoked kernels. It is a view of the normal compiled
plan, not a second scheduler and not a replacement for ordinary `run!`.

Only when the user requests a file artifact, write it explicitly:

```julia
Authoring.write_compiled_model_source("compiled_scenario.jl", scenario)
```

Prefer `compiled_model_source` in memory for inspection and review. Treat the
written file as generated evidence and do not edit it as the source scenario.

## Common diagnosis sequence

### Missing or ambiguous input

1. Check the consumer's declared input name and type.
2. Inspect all candidate producers and application names.
3. Check multiplicity and scope.
4. Add `application=` and `var=` when the source is known.
5. Inspect contracts; do not bypass a mismatch with a rename.

### Cycle

1. Determine whether the edge should be a same-step value dependency, a
   parent-controlled hard call, or a true temporal lag.
2. Use a hard call for controller-owned trial execution.
3. Use `PreviousTimeStep` only when the scientific state has an explicit
   initial value and lag meaning.

### Duplicate writer

1. Determine the canonical owner of the variable.
2. Use `Updates(:x; after=:producer)` only for an intentional ordered update.
3. Use `output_routing=(x=:stream_only,)` when the output should retain a
   stream but not own canonical status.
4. Do not rely on application tuple order to resolve writer conflicts.

### Contract mismatch

1. Compare all five contract fields.
2. Confirm which meaning each model actually uses.
3. Correct an erroneous declaration, or add a named adapter for a real
   conversion.
4. Never remove contracts merely to recover name-only coupling.

### Unexpected slow execution

1. Separate model construction/compilation, lifecycle refresh, steady-state
   stepping, output collection, and compiler/lifecycle instrumentation.
2. Inspect execution batches for accidental heterogeneity.
3. Check whether output volume dominates runtime.
4. Preserve reference carriers and bulk hard-call execution before considering
   lower-level optimization.

## Reporting evidence

Always separate:

- freshly executed validation under the reported path/version;
- facts read from source or a structured descriptor;
- inferred or best-effort metadata;
- proposed scientific choices;
- unresolved scientific information;
- local test status versus remote CI/release status.

Do not describe a UI view, old generated report, or different checkout as the
current runtime result.
