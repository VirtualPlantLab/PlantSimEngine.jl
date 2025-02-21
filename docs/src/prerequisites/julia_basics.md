# Getting started with Julia

PlantSimEngine (as well as its related packages) is written in Julia. The reasons why Julia was chosen are briefly discussed here : [The choice of using Julia](@ref).

Julia is a language that is gaining traction, but it isn't the most widely used in research and data science. 

Many elements will be familiar to those with an R, Python or Matlab background, but there are some noteworthy differences, and if you are new to the language, there will be a few hurdles you might have to overcome to be comfortable using the language.

This section is here to help you with that, and provides a short introduction to the parts of Julia that are most relevant regarding usage of PlantSimEngine.

It is not meant as a full-fledged Julia tutorial. If you are completely new to programming, you may wish to check some other resources first, such as ones found [here](https://docs.julialang.org/en/v1/manual/getting-started/).

If you wish to compare Julia to a specific language, [this page](https://docs.julialang.org/en/v1/manual/noteworthy-differences/#Noteworthy-differences-from-Python) will provide you with a quick overview of the differences.

You can also find a few cheatsheets [here](https://palmstudio.github.io/Biophysics_database_palm/cheatsheets/) as well as a [short introductory notebook](https://palmstudio.github.io/Biophysics_database_palm/basic_syntax/) along with [install instructions](https://palmstudio.github.io/Biophysics_database_palm/installation/)


### Installing Julia

### Installing PlantSimEngine and its dependencies

### Julia environments

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

 

### Variables, functions and arrays -> See the palmstudio basic syntax page, or the diff eq notebook ?

### Really noteworthy differences : 
- Array indexing starts at 1.

### Typing

### Custom types

### Dictionaries

PlantSimEngine makes use of dictionaries to declare and store data, indexed by scale/organ.
For example : 

### Functions 

### Function arguments and kwargs

### NamedTuples