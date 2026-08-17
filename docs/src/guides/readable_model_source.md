# Generate readable model source

A `CompositeModel` is deliberately concise: you provide applications,
selectors, and bindings, and PlantSimEngine compiles their execution order. That
is convenient for running a simulation, but it can hide how the scientific
models call one another.

`compile_model_source` turns that resolved scenario into an ordinary Julia
script intended for people to read. The script shows:

- the root application order and cadence;
- the objects selected by each application;
- the producer of every bound input;
- `PreviousTimeStep` and other temporal configuration;
- manual caller/callee relationships;
- environment and output-routing configuration; and
- the source body of every scientific model kernel.

The generated script is executable, so you can also compare it with the normal
runtime. Execution speed is not its purpose; use `run!` for production runs.

```@contents
Pages = ["readable_model_source.md"]
Depth = 2
```

```@setup readable_model_source
using PlantSimEngine, PlantMeteo, Dates
using PlantSimEngine.Examples
```

## Build the ordinary composite model

This small example composes thermal time, leaf-area development, and light
interception. The model values are pedagogical; the point is to expose the
coupling between applications.

```@example readable_model_source
weather = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples", "meteo_day.csv");
    duration=Dates.Day,
)

function readable_example(weather)
    return CompositeModel(
        ToyDegreeDaysCumulModel(),
        ToyLAIModel(),
        Beer(0.6);
        environment=weather,
    )
end

model = readable_example(weather)
normal = run!(model; steps=3, outputs=:all)
final_state(normal)
```

PlantSimEngine infers that leaf-area development consumes thermal time, then
light interception consumes leaf area. The authored model does not need to
spell out those calls.

## Generate the explanatory script

`compile_model_source` returns deterministic source text for the same resolved
scenario:

```@example readable_model_source
source = compile_model_source(
    readable_example(weather);
    function_name=:run_readable_example!,
)

occursin("Application order", source) &&
    occursin("input :LAI <- application :LAI_Dynamic.LAI", source)
```

Use `write_compiled_model` when the source should be reviewed, taught from,
diffed, or kept beside a scientific analysis:

```@example readable_model_source
source_path = tempname() * ".jl"
write_compiled_model(
    source_path,
    readable_example(weather);
    function_name=:run_readable_example!,
)
read(source_path, String) == source
```

The file is organized in two parts. The first contains clearly named copies of
the model kernels with their original type, source location, declared inputs
and outputs, resolved inputs, and manual calls. The second contains one named
section per root application in execution order. A typical section reads like
this:

```julia
# Application :LAI_Dynamic
# process: :toy_lai
# cadence: dt=1.0, phase=0.0, schedule=always
# target selector: One(scale=:Scene)
# current targets: scene (scale=Scene, kind=scene)
# input :TT_cu <- application :Degreedays.TT_cu via one
if :LAI_Dynamic in due_applications
    # Resolve the current objects, then run the visible scientific kernel once
    # for each selected object.
    for resolved_target in PlantSimEngine._compiled_source_targets(...)
        PlantSimEngine._compiled_source_kernel!(...)
    end
end
```

Low-level helpers retain PlantSimEngine's reference, environment, temporal,
output, and lifecycle semantics. They do not decide model order or hide the
scientific body: those relationships remain visible in the generated file.

## Load and execute the source

Including the file defines the chosen entry point for both a fresh
`CompositeModel` and an existing `Simulation`:

```@example readable_model_source
include(source_path)

generated = run_readable_example!(
    readable_example(weather);
    steps=3,
    outputs=:all,
)

(
    normal=final_state(normal).LAI,
    generated=final_state(generated).LAI,
)
```

The simulation method continues its existing timeline and temporal state:

```@example readable_model_source
run_readable_example!(generated; steps=2)
current_step(generated)
```

The entry point checks a deterministic compatibility signature before running.
Changing application identities, model types, selectors, bindings, manual
calls, cadence, or output routing requires regenerating the file. Object
membership is different: supported lifecycle operations such as
`register_object!`, `add_organ!`, removal, and reparenting refresh concrete
targets at lifecycle barriers while retaining the same generated application
code.

## Manual calls and temporal inputs

For `run_call!`, the copied parent body retains the call at the point where the
scientific model makes it. The generated kernel routes that call to the copied
child kernel, and a nearby comment names the resolved target application and
multiplicity. Nested and fine-grained `CallTarget` execution therefore remain
visible rather than falling back to the optimized generic model executor.

Bindings marked with `PreviousTimeStep` are labeled as previous-timestep inputs
and do not add a same-step ordering edge. Selector policies, windows, cadence,
environment selection, canonical publication, and `:stream_only` routing are
written beside the affected application.

## Supported source and limitations

The readable compiler extracts the five-argument model contract:

```julia
PlantSimEngine.run!(model, status, environment, constants, context)
```

Typed arguments, default arguments, `where` clauses, nested blocks, qualified
`PlantSimEngine.run_call!`, and direct `run_call!` calls are supported. Model
methods must come from an available source file, and the defining modules and
model types must be loadable when the generated file is included.

The compiler rejects ambiguous matching `run!` methods, unavailable source,
non-standard kernel signatures, aliased or dynamically dispatched `run_call!`
expressions, invalid generated function names, and incompatible scenarios. The
error is intentional: readable mode never silently replaces a relationship it
cannot represent with an opaque runtime call.

!!! tip
    Use this feature to explain, audit, review, or archive model orchestration.
    Use `Diagnostics.explain_*` for structured programmatic inspection and the
    normal `run!` executor for production performance.
