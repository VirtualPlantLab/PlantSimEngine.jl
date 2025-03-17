# Installing and running PlantSimEngine

```@contents
Pages = ["installing_plantsimengine.md"]
Depth = 3
```

This page is meant to help along people newer to Julia. If you are quite accustomed to Julia, installing PlantSimEngine should be par for the course, and you can [move on to the next section](#step_by_step), or read about PlantSimEngine's [Key concepts](@ref).

## Installing Julia

The direct download link can be found [here](https://julialang.org/downloads/), and some additional pointers [in the official manual](https://docs.julialang.org/en/v1/manual/installation/).

## Installing VSCode

You can get by using a REPL, but if writing a larger piece of software you may prefer using an IDE. PlantSimEngine is developed using VSCode, which you can install by following instruction [on this page](https://code.visualstudio.com/docs/setup/setup-overview). A documentation section specific to using Julia in VSCode can be found [here](https://code.visualstudio.com/docs/languages/julia).

## Installing PlantSimEngine and its dependencies

### Julia environments

Julia package management is done via the Pkg.jl package. You can find more in-depth sections detailing its usage, and working with Julia environments [in its documentation](https://pkgdocs.julialang.org/v1/)

If you find this page insufficient to get started, [this tutorial](https://jkrumbiegel.com/pages/2022-08-26-pkg-introduction/) explains in detail the subtleties of Julia environments.

### Running an environment

Once your environment is set up, you can launch a command prompt and type `julia`. This will launch Julia, and you should see `julia>` in the command prompt.

You can always type `?` from there to enter help mode, and type the name of a function or language feature you wish to know more about.

You can find out which directory you are in by typing `pwd()` in a Julia session.

Handling environments and dependencies is done in Julia through a specific Package called Pkg, which comes with the base install. You can either call Pkg features the same way you would for another package, or enter Pkg mode by typing `]`, which will change the display from `julia>` to something like `(@v1.11)` pkg>, indicating your current environment (in this case, the default julia environment, which we don't recommend bloating).

Once in Pkg mode, you can choose to create an environment by typing `activate path/to/environment`. 

You can then add packages that have been added to Julia's online global registry by typing `add packagename` and you can remove them by typing `remove packagename`. Typing `status` or `st` will indicate what your current environment is comprised of. To update packages in need of updating (a `^` symbol will display next to their name), type `update`… or `up`.

If you are editing/developing a package or using one locally, typing `develop path/to/package source/` (or `dev path/to/package/source`) will cause your environment to use that version instead of the registered one.

Typing `instantiate` will download all the packages declared in the manifest file (if it exists) of an environment.

For instance, PlantSimEngine has a test folder used in development. If you wanted to run tests, you would type `]` then `activate ../path/to/PlantSimEngine/test` then `instantiate`
and then you would be ready to run some scripts.

So if you wish to use PlantSimEngine, you can enter Pkg mode (`]`), choose an environment folder, then activate that environment with `activate ../path/to/your_environment`, add PlantSimEngine to it with `add PlantSimEngine` then download the package and its dependencies with `instantiate`.

### Companion packages

You'll also, for most of our examples, need `PlantMeteo`. For several multi-scale simulations, you'll need `MultiScaleTreeGraph`.

Some of the weather data examples make use of the `CSV` package, some output data is manipulated as a DataFrame, which is part of the `DataFrames` package.

### Using the example models

Example models are exported as a distinct submodule of PlantSimEngine, meaning they aren't part of the main API. You can use them by typing:

```julia
using PlantSimEngine.Examples
```

## Running a test simulation

Assuming you've setup you're environement, correctly added `PlantMeteo` and `PlantSimEngine` to that environment, and downloaded everything with `instantiate`, you'll be able to run a test example in your REPL by typing line-by-line:

```@example mypkg
using PlantSimEngine, PlantMeteo
using PlantSimEngine.Examples
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))
out_sim = run!(leaf, meteo)
```

## Environements in VSCode

There is detailed documentation explaining how to make use of Julia with VSCode with one section indicating how to handle environments in VSCode: [https://www.julia-vscode.org/docs/stable/userguide/env/](@ref)
 