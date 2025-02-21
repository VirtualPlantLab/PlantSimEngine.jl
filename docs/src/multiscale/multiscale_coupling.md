
# Handling dependencies in a multiscale context

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
    name_provided_in_the_mapping=AbstractHardDependencyModel => ["Organ_Name_1",],
)
```

 Here's a concrete example in [XPalm](https://github.com/PalmStudio/XPalm.jl), an oil palm model developed on top of PlantSimEngine. 
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