# Compile a PlantSimEngine scenario with JuliaC

The JuliaC experiment builds a command-line executable for an application whose
models, coupling rules and supported operations are known at build time. The
application can still take values such as simulation length and model parameters
at run time. Each executable mode has its own input schema.

Start with a shipped scenario to see how the build and parity checks fit
together. To compile your own scenario, use the matching example as a starting
point and write an application entry point for it. PlantSimEngine currently
provides the ordinary `run!` workflow for general `CompositeModel` scenarios.
The JuliaC experiment has no public `compile(model)` method.

## Build and run the examples

From a PlantSimEngine checkout that contains this experiment, use Julia 1.13.1
and a working C compiler to match the reference environment. The
[app project](app/Project.toml) pins XPalm and uses the local PSE checkout.
The separate [build project](buildenv/Project.toml) pins JuliaC 0.3.12.
Keep the resolved manifests if you need to replay the exact dependency
resolution. The [archived XPalm report](results/full/README.md) records the
revision, platform and inputs behind its results.

The paths below are relative to `benchmark/juliac_program/`. With Kaimon, open
two sessions rooted at `app/` and `buildenv/` respectively.

1. Instantiate the `app/` project. In a Julia session with that project active,
   run `using Pkg; Pkg.instantiate()`. This also ensures the pinned XPalm
   sources are available for the build.
2. Start a separate Julia session with `buildenv/` active and instantiate it.
   From that directory, run `include("../build.jl")`. The script compiles with safe trimming,
   links with relative library paths, bundles the runtime and installs a
   launcher. It writes the new bundle path to `build/latest.txt` by default.
3. From `benchmark/juliac_program/`, run the launcher from a shell.

   ```sh
   bundle=$(cat build/latest.txt)
   "$bundle/bin/run-pse-program" fixture 1 3 0 0 10 0.5 0.25 20.0
   "$bundle/bin/run-pse-program" full 12 0.3 true
   ```

   The first command runs a small assimilation and accumulation example. The
   second runs the selected XPalm `architecture=false` graph with synthetic
   forcing and accelerated reproductive parameters. The fixture prints
   `1,3,11.5,8.25`. The XPalm output starts with `F,54,12,61`, which gives
   the object count, day count and application count. Keep the whole bundle
   together when moving it.

4. In a clean Julia session rooted at `app/`, compare the XPalm executable with
   the ordinary PSE reference. The checker uses `build/latest.txt` by default.

   ```julia
   include("../full_xpalm_native_checks.jl")
   FullXPalmNativeChecks.run_checks()
   ```

   This checks topology, scientific state, retained outputs and RNG probes.
   It also runs a copied bundle on the same host. For other graphs, see the
   package-specific [AMAPSim](https://github.com/VEZY/AMAPSim.jl/pull/14)
   and [MAESPA](https://github.com/VEZY/MAESPA.jl/pull/15) harnesses.

## Adapt an example to your scenario

First run your scenario through ordinary PSE and save a short reference case.
If the model grows, uses random draws or publishes outputs from child calls,
choose inputs that exercise those paths. Then use the
[two-kernel fixture](app/src/fixture.jl) and
[application entry point](app/src/PSEProgramApp.jl) as a template.

Declare the scenario's models and routes with `ModelSpec`. Choose the
build-time graph and the values the executable should accept at run time.
Write a small `@main` entry point that validates those values, constructs the
typed state expected by the chosen executor and runs the simulation. The
fixture's internal `ReusableProgram.prepare` lowers a supported tuple of
`ModelSpec` declarations. The full XPalm and downstream entry points show
how larger scenarios need their own preparation and runtime boundaries.
JuliaC builds the resulting application using its normal compile, link and
bundle steps. [JuliaC documentation](https://github.com/JuliaLang/JuliaC.jl)

| If you hit this | What to check |
| --- | --- |
| The preparation step rejects a model or route | Check the executor's supported features. The small fixture expects one object kind, one fixed cadence, scalar state, same-object inputs and singleton same-object calls. The full XPalm executor supports its specific growth, distributed outputs and `PreviousTimeStep` routes. A feature can work in ordinary PSE and still require a different native executor. |
| Safe trimming rejects a call | Start with the first unresolved call in the compiler log. Follow the values reaching it. Fields typed as `Any`, abstract containers in the numerical loop and run-time method or model lookup can prevent the compiler from knowing what code to keep. Pass concretely typed models and inputs to the kernel. Keep ordinary Julia's flexibility when it does not reach the native entry point. |
| The kernel discovers models, reads configuration or builds a graph dynamically | Resolve fixed model choices and routing during preparation when possible. Pass data through an explicit input schema. Reflection, `eval`, dynamic loading and live graph inspection require special care at the compiled boundary. Keep file and configuration work outside the numerical loop where the application permits it. |
| The model has mutable state or RNGs | Give each simulation its own state and preserve intentional aliases, draw order and seeds. A build that succeeds can still change the science if these semantics are lost. |
| The executable starts locally and fails after being moved | Copy the whole bundle, use its launcher and test it from an empty working directory. Check artifacts and runtime data files on the intended target. The archived XPalm relocation is for the same host. |

Keep safe trimming enabled while diagnosing a verifier rejection. After a
successful build, compare the executable with ordinary PSE before measuring
speed. Compare the output history and topology as well as final values when
those are part of the result. Time compilation, startup and simulation
separately so each comparison measures the same work on both paths.

A future public API could take a scenario recipe and input schema, report
unsupported features, then build and verify a bundle for admitted scenarios.
The shipped build script already automates compilation and bundling once an
application entry point exists. Automatic lowering of arbitrary PSE scenarios
would also need admission checks and coverage of their run-time operations.
