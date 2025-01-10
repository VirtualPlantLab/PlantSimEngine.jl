mapping = Dict(
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(TT=10.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(aPPFD=1300.0, TT=10.0),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

dep_graph = dep(mapping)

# The C allocation depends on the C demand at the leaf and internode levels,
# the maintenance respiration at the plant level, and the maintenance respiration at the plant level,
# which depends on the maintenance respiration at the leaf and internode levels.

# Expected root dependency nodes:
root_models = Dict(
    ("Soil" => :soil_water) => mapping["Soil"][1], # The only model from the soil is completely independent  
    ("Internode" => :carbon_demand) => mapping["Internode"][1], # The c allocation models dependent on TT, that is given as input:
    ("Leaf" => :carbon_demand) => mapping["Leaf"][2], # Same for the leaf
    ("Internode" => :maintenance_respiration) => mapping["Internode"][2], # The maintenance respiration model for the internode is independant
    ("Leaf" => :maintenance_respiration) => mapping["Leaf"][3], # The maintenance respiration model for the leaf is independant
)

for (proc, node) in dep_graph.roots # proc = ("Soil" => :soil_water) ; node = dep_graph.roots[proc]
    @test root_models[proc] == node.value
end



###########################
### ModelList vs Mapping comparison
### and Mapping with custom models vs mapping with generated models for user-provided vector
###########################

function compare_outputs_modellist_mapping(models, graphsim)
    graphsim_df = outputs(graphsim, DataFrame)

    graphsim_df_outputs_only = select(graphsim_df, Not([:timestep, :organ, :node]))
    models_df = DataFrame(status(models))
    
    models_df_sorted = models_df[:, sortperm(names(models_df))]
    graphsim_df_outputs_only_sorted = graphsim_df_outputs_only[:, sortperm(names(graphsim_df_outputs_only))]
    return graphsim_df_outputs_only_sorted == models_df_sorted
end

function modellist_to_mapping(modellist_original::ModelList, modellist_status, nsteps; check=true, outputs=nothing, TT_cu_vec=Vector{Float64}())
    
    modellist = Base.copy(modellist_original, modellist_original.status)

    default_scale = "Default"
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", default_scale, 0, 0),)

    #models = collect(values(object))
    models = modellist.models
    #status_ts = modellist.status.ts

    mapping = Dict(
        default_scale => (
        models..., 
        ToyTestDegreeDaysCumulModel(TT_cu_vec=TT_cu_vec),
        MultiScaleModel(
        model=ToyCurrenttimestepModel(),
        mapping=[PreviousTimeStep(:next_timestep),],
        ),
        #Status(status),
        Status(current_timestep=1,next_timestep=1)
        ),
    )
    
    if isnothing(outputs)
        f = []
        for i in 1:length(modellist.models)
            aa = init_variables(modellist.models[i])
            bb = keys(aa)
            for j in 1:length(bb)
                push!(f, bb[j])
            end
            #f = (f..., bb...)
        end

        f = unique!(f)
        all_vars = (f...,)
        #all_vars = merge((keys(init_variables(object.models[i])) for i in 1:length(object.models))...)
    else 
        all_vars = outputs
        # TODO sanity check
    end

   #=run!(mtg, mapping,
    meteo_day,
    constants=PlantMeteo.Constants(),
    extra=nothing,
    nsteps = nsteps,
    outputs = all_vars,
    check=true,
    executor=ThreadedEx()
)=#

    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=check, outputs=Dict(default_scale => all_vars))
    return sim
end

PlantSimEngine.@process "Currenttimestep" verbose = false

struct ToyCurrenttimestepModel <: AbstractCurrenttimestepModel
end

PlantSimEngine.inputs_(::ToyCurrenttimestepModel) = (next_timestep=1,)
PlantSimEngine.outputs_(m::ToyCurrenttimestepModel) = (current_timestep=1,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyCurrenttimestepModel, models, status, meteo, constants=nothing, extra=nothing)
    status.current_timestep = status.next_timestep
 end 

PlantSimEngine.@process "Degreedays" verbose = false

struct ToyTestDegreeDaysCumulModel <: AbstractDegreedaysModel
    TT_cu_vec::Vector{Float64}
end

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyTestDegreeDaysCumulModel) = (current_timestep=1,)
PlantSimEngine.outputs_(::ToyTestDegreeDaysCumulModel) = (TT_cu=0.0, next_timestep=1)

ToyTestDegreeDaysCumulModel(; TT_cu_vec = Vector{Float64}()) = ToyTestDegreeDaysCumulModel(TT_cu_vec)


# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyTestDegreeDaysCumulModel, models, status, meteo, constants=nothing, extra=nothing)
    status.TT_cu = m.TT_cu_vec[status.current_timestep]
    status.next_timestep = status.current_timestep + 1
end

# having the current_timestep means it is not object-dependent, and is a scene model in a multiscale simulation
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyTestDegreeDaysCumulModel}) = PlantSimEngine.IsObjectDependent()



function replace_status_vectors_with_models(mapping, meteo)

    #create dict of models <-> scale
    #remove vectors from the statuses
    #then fiddle with the mapping to remove what is necessary ? or add new models, and add the current_timestep (it needs to be multiscale)
end


generated_models = ()
# TODO call this function when generating the simulation graph
# issue, how to reinsert this model back into the mapping ?
# TODO name conflict -> UUID
function generate_model_from_status_vector_variable(mapping, timestep_scale, status, organ)

    new_status = NamedTuple()
    #var = keys(st)[1]
    #var_vals = values(st)[1]
    #print(typeof(status))
    for symbol in keys(status)
        value = getproperty(status, symbol)
        if isa(value, AbstractVector)

            var_type = eltype(value)
            process_name = lowercase(string(symbol)) # TODO + ### UUID ###
         
            process_decl = "PlantSimEngine.@process \"$process_name\" verbose = false\n\n"
            eval(Meta.parse(process_decl))
            
            var_titlecase::String = titlecase(string(symbol))
            model_name = "My$(var_titlecase)Model"
            process_abstract_name = "Abstract$(var_titlecase)Model"
            var_vector = "$(symbol)_vector"
    
            struct_decl::String = "struct $model_name <: $process_abstract_name \n$var_vector::$var_type \nend\n\n"
            eval(Meta.parse(struct_decl))
            
            inputs_decl::String = "function PlantSimEngine.inputs_(::$model_name)\n(:current_timestep,)\nend\n\n"
            eval(Meta.parse(inputs_decl))
    
            outputs_decl::String = "function PlantSimEngine.outputs_(::$model_name)\n(:($var),)\nend\n\n"
            eval(Meta.parse(outputs_decl))
    
            #constructor
            constructor_decl =  "$model_name(; $var_vector = Vector{$var_type}()) = $model_name($var_vector)\n\n"
            eval(Meta.parse(constructor_decl))
    
            run_decl = "function PlantSimEngine.run!(m::$model_name, models, status, meteo, constants=nothing, extra_args=nothing)\nstatus.$var = m.$var_vector[status.current_timestep]\nend\n\n"
            eval(Meta.parse(run_decl))
    
            # add name to vector of models
            if timestep_scale != organ
                mapping_decl = "mapping[\"($organ)\"] = MultiScaleModel($process_name($var_vector), mapping=\"($timestep_scale)\" => (:current_timestep,))"
                eval(Meta.parse(mapping_decl))
            else
            end 
        
        model_add_decl = "generated_models = (generated_models..., $model_name(1),)"
        eval(Meta.parse(model_add_decl))
        else
            #setproperty!(new_status, symbol, value)
            new_status = (new_status..., symbol => value)
        end
    end
    
    @assert length(status) == length(new_status) + length(generated_models) "Error during generation of models from vector values provided at the $organ-level status"
    return new_status, generated_models
end


#todo remove from status, add into mapping
function modellist_to_mapping_2(modellist_original::ModelList, modellist_status, nsteps; check=true, outputs=nothing)
    
    modellist = Base.copy(modellist_original, modellist_original.status)

    default_scale = "Default"
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", default_scale, 0, 0),)

    #models = collect(values(object))
    models = modellist.models
    #status_ts = modellist.status.ts

    mapping_incomplete = Dict(
        default_scale => (
        models..., 
        MultiScaleModel(
        model=ToyCurrenttimestepModel(),
        mapping=[PreviousTimeStep(:next_timestep),],
        ),
        #Status(status),
        Status((modellist_status..., current_timestep=1,next_timestep=1,))
        ),
    )
    
    timestep_scale = "Default"
    organ = "Default"
 
    st = (last(mapping_incomplete["Default"]))
    new_status, generated_models =  generate_model_from_status_vector_variable(mapping_incomplete, timestep_scale, st, organ)

    mapping = Dict(default_scale => (
        models..., generated_models..., 
        MultiScaleModel(
            model=ToyCurrenttimestepModel(),
            mapping=[PreviousTimeStep(:next_timestep),],
            ),
            Status(new_status,)
    ),
    )

    if isnothing(outputs)
        f = []
        for i in 1:length(modellist.models)
            aa = init_variables(modellist.models[i])
            bb = keys(aa)
            for j in 1:length(bb)
                push!(f, bb[j])
            end
            #f = (f..., bb...)
        end

        f = unique!(f)
        all_vars = (f...,)
        #all_vars = merge((keys(init_variables(object.models[i])) for i in 1:length(object.models))...)
    else 
        all_vars = outputs
        # TODO sanity check
    end

   #=run!(mtg, mapping,
    meteo_day,
    constants=PlantMeteo.Constants(),
    extra=nothing,
    nsteps = nsteps,
    outputs = all_vars,
    check=true,
    executor=ThreadedEx()
)=#

    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=check, outputs=Dict(default_scale => all_vars))
    return sim
end


#@testset "ModelList and Mapping result consistency" begin

    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

    st = (TT_cu=cumsum(meteo_day.TT),)
    TT_cu_vec = Vector(cumsum(meteo_day.TT))

    rue = 0.3
    models = ModelList(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue),
        status=st,
    )

   run!(models,
        meteo_day
        ;
        check=true,
        executor=ThreadedEx()
    )

    nsteps = nrow(meteo_day)
    graphsim = modellist_to_mapping(models, st, nsteps; outputs=nothing, TT_cu_vec=TT_cu_vec)

    # need to pass parameters from modellist to mapping
    # status isn't an issue (apart from vectors needing handling),
    # and models aren't either, but parameters provided to the model objects don't get passed through
    # so recreating an object with the parameters provided again is a necessity, here's code that tries to get the params and do so
    # lai = models.models[1]
    # This works, need to replace the model by a constructor somehow
    #ToyLAIModel((getproperty(lai,i) for i in fieldnames(typeof(lai)))...)
    # model_type = typeof(models.models[1])
    # typeof(models.models[1])((getproperty(model_type,i) for i in fieldnames(model_type))...)
    # model_type((getproperty(lai,i) for i in fieldnames(typeof(lai)))...)

    # todo multiscale test with vectors provided at different scales

    #PlantSimEngine.check_simulation_id(graphsim, 1)

    sim = run!(graphsim,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=ThreadedEx()
    )
    sim

    @test compare_outputs_modellist_mapping(models, graphsim)

    # fully automated model generation
    st2 = (TT_cu=Vector(cumsum(meteo_day.TT)),)
    #timestep_scale = "Default"
    #organ = "Default"
    #mapping = Dict()
    #generate_model_from_status_vector_variable(mapping, timestep_scale, st2, organ)
    
    graphsim2 = @enter modellist_to_mapping_2(models, st2, nsteps; outputs=nothing)#, TT_cu_vec=TT_cu_vec)
    sim2 = run!(graphsim2,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=ThreadedEx()
    )
    @test compare_outputs_modellist_mapping(models, graphsim2)

#end