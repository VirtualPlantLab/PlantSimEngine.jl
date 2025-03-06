# Tips and workarounds

## PlantSimEngine is actively being developed

PlantSimEngine, despite the somewhat abstract codebase and generic simulation ambitions, is quite grounded in reality. There IS a desire to accomodate for a wide range of possible simulations, without constraining the user too much, but most features are developed on an as-needed basis, and grow out of necessity, partly from the requirements of an increasingly complex and refined implementation of an oil palm model, [XPalm](https://github.com/PalmStudio/XPalm.jl).

Since the oil palm model is actively being developed, and some features aren't ready in PlantSimEngine, or require a lot of rewriting that we're not certain would be worth it (especially if it ends up constraining the codebase or what the user can do), some workarounds and shortcuts are occasionally used to circumvent a limitation. 

There are also a couple of features that are quick hacks or that are meant for quick and dirty prototyping, not for production. 

We'll list a few of them here, and will likely add some entry in the future listing some built-in limitations or implicit expectations of the package.

## Making use of past states in multi-scale simulations

It is possible to make use of the value of a variable in the past simulation timestep via the `PreviousTimeStep` mechanism in the mapping API (In fact, as mentioned elsewhere, it is the default way to break undesirable cyclic dependencies that can come up when coupling models, see : [Avoiding cyclic dependencies](@ref)).

However, it is not possible to go beyond that through the mapping API. Something like `PreviousTimeStep(PreviousTimeStep(PreviousTimeStep(:carbon_biomass)))` is not supported. Don't do that.

One way to access prior variable states is simply to write an ad hoc model that stores a few values into an array or however many variables you might need, which you can then update every timestep and feed into other models that might need it.

## Having a variable simultaneously as input and output of a model 

One current limitation of `PlantSimEngine` that can be occasionally awkward is that using the same variable name as input and output in a single model is unsupported. 

(On a related note : it is not possible to have two variables with the same name *in the same scale*. They are considered as the same variable.)

The reason being that it is usually impossible to automatically determine how the coupling is supposed to work out, when other dependencies latch onto such a model. The user would have to explicitely declare some order of simulation between several models, and some amount of programmer work would also be necessary to implement that extra API feature into `PlantSimEngine`.

We haven't found an approach that was fully satisfactory from both a code simplicity and an API convenience POV. Especially when prototyping and adding in new models, as that might require redeclaring the simulation order for those specific variables.

There are two workarounds : 

One awkward approach is to rename one of the variables. It is not ideal, of course, as it means you might not be able to use a predefined model 'out of the box', but it does not have any of the tradeoffs and constrained mentioned above.

In many other situations one can work with what PlantSimEngine already provides.

For example, one model in [XPalm.jl](https://github.com/PalmStudio/XPalm.jl/blob/main/src/plant/phytomer/leaves/leaf_pruning.jl) handles leaf pruning, affecting biomass. A straightforward implementation would be to have a `leaf_biomass` variable as both input and output. The workaround is to instead output a variable `leaf_biomass_pruning_loss` and to have that as input in the next timestep to compute the new leaf biomass.

TODO use toy plant as example

## [Multiscale : passing in a vector in a mapping status at a specific scale](@id multiscale_vector)

TODO example from single to multiscale

You may have noticed that sometimes a vector (1-dimensional array) variable is passed into the `status` component of a `ModelList` in documentation examples (An example here with cumulative thermal time : [Model switching](@ref)).

This is practical for simple simulations, or when quickly prototyping, to avoid having to write a model specifically for it. Whatever models make use of that variable are provided with one element corresponding to the current timestep every iteration.

In multi-scale simulations, this feature is also supported, though not part of the main API. The way outputs and statuses work is a little different, so that little convenience feature is not as straightforward. 

It is more brittle, makes use of not-recommended Julia metaprogramming features (`eval()`), fiddles with global variables, might not work outside of a REPL environment and is not tested for more complex interactions, so it may interact badly with variables that are mapped to different scales or in bizarre dependency couplings.

Due to, uh, implementation quirks, the way to use this is as follows : 

Call the function `replace_mapping_status_vectors_with_generated_models(mapping_with_vectors_in_status, timestep_model_organ_level, nsteps)`on your mapping.

It will parse your mapping, generate custom models to store and feed the vector values each timestep, and return the new mapping you can then use for your simulation. It also slips in a couple of internal models that provide the timestep index to these models (so note that symbols `:current_timestep` and `:next_timestep` will be declared for that mapping). You can decide which scale/organ level you want those models to be in via the `timestep_model_organ_level`parameter. `nsteps` is used as a sanity check, and expects you to provide the amount of simulation timesteps.

!!! note
    Only subtypes of AbstractVector present in statuses will be affected. In some cases, meteo values might need a small conversion. For instance :
    ```
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    status(TT_cu=cumsum(meteo_day.TT),)```

    cumsum(meteo_day.TT) actually returns a CSV.SentinelArray.ChainedVectors{T, Vector{T}}, which is not a subtype of AbstractVector. 
    Replacing it with Vector(cumsum(meteo_day.TT)) will provide an adequate type.

This feature is likely to break in simulations that make use of planned future features (such as mixing models with different timesteps), without guarantee of a fix on a short notice. Again, bear in mind it is mostly a convenient shortcut for prototyping, when doing multi-scale simulations.

TODO examples of other ad hoc models
TODO state machines ?
TODO workaround status initialisation bug ?

## Cyclic dependencies in single-scale simulations

Cyclic dependencies can happen in single-scale simulations, but the PreviousTimestep feature currently isn't available. Hard dependencies are one way to deal with them, creating a multi-scale simulation with a single effective scale is also an option.