# Compile a fixed scenario with JuliaC

PlantSimEngine can prepare a fixed one-object `CompositeModel` for a
standalone executable. You choose the models and connections in the app's
source code. The app can accept data at runtime, such as the number of
simulation steps. The ordinary `run!` workflow supports the broader range
of PlantSimEngine scenarios.

## Compare the two executions in Julia

The repository's `examples/compiled_scenario` app contains two teaching
models. One provides an increment of `2.5` at every step and the other adds
that increment to a running total. The consumer is listed first in the
`CompositeModel`. PlantSimEngine's scenario plan puts the producer first
because the consumer needs its output.

```@example compile_scenario
using PlantSimEngine
include(joinpath(pkgdir(PlantSimEngine), "examples", "compiled_scenario", "src", "PSECompiledScenario.jl"))

ordinary = run!(PSECompiledScenario.make_model(); steps=4, outputs=:none)
program = Compilation.prepare(PSECompiledScenario.make_model())
continue!(program; steps=2)
step!(program)
step!(program)
@assert final_state(program) == final_state(ordinary)
(current_step=current_step(program), total=final_state(program).total)
```

`Compilation.prepare` takes a fresh authored `CompositeModel`. It resolves
its schedule and input bindings and gives the program its own status.
The supplied model stays available for an ordinary run. Use `current_step`
and `final_state` to inspect the program, and `continue!` or `step!` to
advance it.

## Build the example executable

Use Julia 1.13.1, JuliaC 0.3.12 and a working C compiler to match the qualified
build. From the root of a PlantSimEngine checkout, instantiate the named app
project once:

```sh
julia --project=examples/compiled_scenario -e 'using Pkg; Pkg.instantiate()'
```

The app project points to the local PlantSimEngine checkout in `[sources]`.
Use a separate environment for the build tools. From the repository root,
start Julia and run:

```julia
using Pkg
Pkg.activate(; temp=true)
Pkg.develop(path=pwd())
Pkg.add(Pkg.PackageSpec(name="JuliaC", version=v"0.3.12"))

using JuliaC, PlantSimEngine
bundle = Compilation.compile(
    abspath("examples", "compiled_scenario");
    destination=abspath("compiled-scenario"),
    name="simulation",
)
```

Choose a destination that does not yet exist. `Compilation.compile` uses safe
trimming and a generic CPU target. It returns the bundle's `directory` and
`executable` paths. JuliaC is only needed in the build environment. [JuliaC](https://github.com/JuliaLang/JuliaC.jl)

From a shell at the repository root, run the built executable. The two
commands should each print `4,10.0`.

```sh
./compiled-scenario/bin/simulation 4
./compiled-scenario/bin/simulation 2 2
```

The second command advances one program in two chunks. It keeps the
accumulated state between chunks. Keep the whole bundle together when
moving it. If your app uses bundled artifacts, point `JULIA_DEPOT_PATH` to
the bundle's `share/julia` directory when running it.

## Adapt the app to your model

Define your scenario in a named package with a `Project.toml` and a
`src/PackageName.jl` module. In the module, call
`const program = Compilation.prepare(make_model())` and add a `@main`
entry point. Use the entry point to parse arguments, advance the program,
and write the result. JuliaC loads the module during the build, so put the
fixed scenario in `make_model()` and handle runtime data in the entry point.

This compiler admits one ordinary object with same-object scalar inputs and
outputs. All applications run at every base step. Status values must be
numeric bits values such as `Float32`, `Float64` or `Int`, and model and
constant types must be immutable bits types. Use fields with concrete types
and write kernels that can run without inspecting a live scenario registry.

Models that need multiple objects, an MTG, mounted instances, environment
inputs, different cadences, temporal inputs, hard calls, initializers,
distributed or stream-only outputs, topology edits, or retained histories
can run through the ordinary PlantSimEngine API.

If preparation rejects a model, read the reported application or feature
and check it against this list. If JuliaC's safe verifier rejects a call,
start with the first unresolved call in its error output. Check the types
of its arguments and look for abstract containers, dynamic method lookup,
`eval`, or reflection on that path. Keep data parsing and file access in
the entry point where possible. After building, compare representative
final states and split runs with an independent ordinary `run!` before
measuring performance.
