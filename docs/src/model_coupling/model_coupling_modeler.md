# Model coupling for modelers

```@setup usepkg
using PlantSimEngine, PlantMeteo
# Import the example models defined in the `Examples` sub-module:
using PlantSimEngine.Examples

m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
)
```

This section uses notions from the previous section. If you are not familiar with the concepts of model coupling in PlantSimEngine, please read the previous section first: [Model coupling for users](@ref).

## Hard coupling

A model that calls explicitly another process is called a hard-coupled model. It is implemented by calling the process function directly.

Let's go through the example processes and models from a script provided by the package here [examples/dummy.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/dummy.jl)

In this script, we declare seven processes and seven models, one for each process. The processes are simply called "process1", "process2"..., and the model implementations are called `Process1Model`, `Process2Model`...

`Process2Model` calls `Process1Model` explicitly, which defines `Process1Model` as a hard-dependency of `Process2Model`. The is as follows:

```julia
function PlantSimEngine.run!(::Process2Model, models, status, meteo, constants, extra)
    # computing var3 using process1:
    run!(models.process1, models, status, meteo, constants)
    # computing var4 and var5:
    status.var4 = status.var3 * 2.0
    status.var5 = status.var4 + 1.0 * meteo.T + 2.0 * meteo.Wind + 3.0 * meteo.Rh
end
```

We see that coupling a model (`Process2Model`) to another process (`process1`) is done by calling the `run!` function again. The `run!` function is called with the same arguments as the `run!` function of the model that calls it, except that we pass the process we want to simulate as the first argument.

!!! note
    We don't enforce any type of model to simulate `process1`. This is the reason why we can switch so easily between model implementations for any process, by just changing the model in the `ModelList`.

A hard-dependency must always be declared to PlantSimEngine. This is done by adding a method to the `dep` function. For example, the hard-dependency to `process1` into `Process2Model` is declared as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=AbstractProcess1Model,)
```

This way PlantSimEngine knows that `Process2Model` needs a model for the simulation of the `process1` process. Note that we don't add any constraint to the type of model we have to use (we use `AbstractProcess1Model`), because we want any model implementation to work with the coupling, as we only are interested in the value of a variable, not the way it is computed.

Even if it is discouraged, you may have a valid reason to force the coupling with a particular model, or a kind of models though. For example, if we want to use only `Process1Model` for the simulation of `process1`, we would declare the dependency as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=Process1Model,)
```

## Soft coupling

A model that takes outputs of another model as inputs is called a soft-coupled model. There is nothing to do on the modeler side to declare a soft-dependency. The detection is done automatically by PlantSimEngine using the inputs and outputs of the models.

## Handling dependencies in a multiscale context

 If a model requires some input variable that is computed at another scale, providing the appropriate mapping will resolve name conflicts and enable proper use of that variable and there will be no extra steps for the user or the modeler.

 In the case of a hard dependency that operates at a different scale from its parent, the same principle applies and there are also no extra steps on the user-side. 
 
 On the other hand, modelers need to bear in mind a couple of subtleties when developing models that possess hard dependencies that operate at a different organ level from their parent : 

 The parent model directly handles the call to its hard dependency model(s), meaning they are not explicitely managed by the dependency graph.
 Therefore only the owning model of that dependency is visible in the graph, and its hard dependency nodes are internal.
 
 When the caller (or any downstream model that requires some variables from the hard dependency) operates at the same scale, variables are easily accessible, and no mapping is required. 

 If an inner model operates at a different scale/organ level, a modeler must declare hard dependencies with their respective organ level, similarly to the way the user provides a mapping. 

 Conceptually :

```julia
 PlantSimEngine.dep(m::ParentModel) = (
    name_provided_in_the_mapping=AbstractHardDependecyModel => ["Organ_Name_1",],
)
```

 Here's a concrete example in XPalm, an oil palm model developed on top of PlantSimEngine. 
 Organs are produced at the phytomer scale, but need to run an age model and a biomass model at the reproductive organs' scales.

```julia
 PlantSimEngine.dep(m::ReproductiveOrganEmission) = (
    initiation_age=AbstractInitiation_AgeModel => [m.male_symbol, m.female_symbol],
    final_potential_biomass=AbstractFinal_Potential_BiomassModel => [m.male_symbol, m.female_symbol],
)
```

The user-mapping includes the required models at specific organ levels. Here's the relevant portion of the mapping for the male reproductive organ :

```julia
mapping = Dict(
    ...
    "Male" =>
    MultiScaleModel(
        model=XPalm.InitiationAgeFromPlantAge(),
        mapping=[:plant_age => "Plant",],
    ),
    ...
    XPalm.MaleFinalPotentialBiomass(
        p.parameters[:male][:male_max_biomass],
        p.parameters[:male][:age_mature_male],
        p.parameters[:male][:fraction_biomass_first_male],
    ),
    ...
)
```

The model's constructor provides convenient default names for the scale corresponding to the reproductive organs. A user may override that if their naming schemes or MTG attributes differ.

```julia
function ReproductiveOrganEmission(mtg::MultiScaleTreeGraph.Node; phytomer_symbol="Phytomer", male_symbol="Male", female_symbol="Female")
    ...
end
```

But how does a model M calling a hard dependency H provide H's variables when calling H's `run!` function ? The status the user provides M operates at M's organ level, so if used to call H's run! function any required variable for H will be missing.    

PlantSimEngine provides what are called Status Templates in the simulation graph. Each organ level has its own Status template listing the available variables at that scale.
So when a model M calls a hard dependency H's `run!` function, any required variables can be accessed through the status template of H's organ level.

Using the same example in XPalm : 

```julia
# Note that the function's 'status' parameter does NOT contain the variables required by the hard dependencies as the calling model's organ level is "Phytomer", not "Male" or "Female"

function PlantSimEngine.run!(m::ReproductiveOrganEmission, models, status, meteo, constants, sim_object)
    ...
    status.graph_node_count += 1

    # Create the new organ as a child of the phytomer:
    st_repro_organ = add_organ!(
        status.node[1], # The phytomer's internode is its first child 
        sim_object,  # The simulation object, so we can add the new status 
        "+", status.sex, 4;
        index=status.phytomer_count,
        id=status.graph_node_count,
        attributes=Dict{Symbol,Any}()
    )

    # Compute the initiation age of the organ:
    PlantSimEngine.run!(sim_object.models[status.sex].initiation_age, sim_object.models[status.sex], st_repro_organ, meteo, constants, sim_object)
    PlantSimEngine.run!(sim_object.models[status.sex].final_potential_biomass, sim_object.models[status.sex], st_repro_organ, meteo, constants, sim_object)
end
```

In the above example the organ and its status template are created on the fly.
When that isn't the case, the status template can be accessed through the simulation graph :

```julia
function PlantSimEngine.run!(m::ReproductiveOrganEmission, models, status, meteo, constants, sim_object)

    ...

    if status.sex == "Male"

        status_male = sim_object.statuses["Male"][1]
        run!(sim_object.models["Male"].initiation_age, models, status_male, meteo, constants, sim_object)
        run!(sim_object.models["Male"].final_potential_biomass, models, status_male, meteo, constants, sim_object)
    else
        # Female
        ...
    end
end
```