# Installing and running PlantSimEngine

## Installing Julia

The direct download link can be found [here](https://julialang.org/downloads/), and some additional pointers [in the official manual](https://docs.julialang.org/en/v1/manual/installation/).

## Installing VSCode

You can get by using a REPL, but if writing a larger piece of software you may prefer using an IDE. PlantSimEngine is developed using VSCode, which you can install by following instruction [on this page](https://code.visualstudio.com/docs/setup/setup-overview). A documentation section specific to using Julia in VSCode can be found here (https://code.visualstudio.com/docs/languages/julia).

## Installing PlantSimEngine and its dependencies

### Julia environments

Julia package management is done via the Pkg.jl package. You can find more in-depth sections detailing its usage, and working with Julia environments [in its documentation](https://pkgdocs.julialang.org/v1/)

### Running an environment

Once your environment is set up, you can launch a command prompt and type 'julia'. This will launch Julia, and you should see
julia> 
in the command prompt.

You can always type '?' from there to enter help mode, and type the name of a function or language feature you wish to know more about.

You can find out which directory you are in by typing pwd() in a Julia session.

Handling environments and dependencies is done in Julia through a specific Package called Pkg, which comes with the base install. You can either call Pkg features the same way you would for another package, or enter Pkg mode by typing ']', which will change the display from 
julia> to something like (@v1.11) pkg>, indicating your current environment (in this case, the default julia environment, which we don't recommend bloating).

Once in Pkg mode, you can choose to create an environment by typing 'activate path/to/environemnt'. 

You can then add packages that have been added to Julia's online global registry by typing add packagename and you can remove them by typing remove packagename. Typing status or st will indicate what your current environment is comprised of. To update packages in need of updating (a '^' symbol will display next to their name), type update or up.

If you are editing/developing a package or using one locally, typing develop path/to/package source/ (or dev path/to/package/source) will cause your environment to use that version instead of the registered one.

Typing instantiate will download all the packages declared in the manifest file (if it exists) of an environment.

For instance, PlantSimEngine has a test folder used in development. If you wanted to run tests, you would type
']'
'activate ../path/to/PlantSimEngine/test'
'instantiate'
and then you would be ready to go.

## Running a test simulation

## Using the example models

## Companion packages
 