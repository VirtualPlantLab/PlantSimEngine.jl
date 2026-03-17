# Utilities to handle vectors passed into a mapping's statuses
# This is a convenience when prototyping, not recommended for production or proper fitting
# (Write the actual finalised model explicitely instead)


# Status vectors are turned into regular runtime models so they can participate in
# dependency inference without relying on top-level eval or world-age-sensitive
# method generation.

# There will still be brittleness given that it's not trivial to handle user/modeler errors : 
# For instance, providing a vector that is called in a scale mapping is likely to cause things to go badly

# May need some more complex timestep models in the future
# TODO : unhandled case : what if the timestep models are already in the provided modellist ?

# These models might be worth exposing in the future ?
PlantSimEngine.@process "basic_current_timestep" verbose = false

struct HelperCurrentTimestepModel <: AbstractBasic_Current_TimestepModel
end

PlantSimEngine.inputs_(::HelperCurrentTimestepModel) = (next_timestep=1,)
PlantSimEngine.outputs_(m::HelperCurrentTimestepModel) = (current_timestep=1,)

function PlantSimEngine.run!(m::HelperCurrentTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
    status.current_timestep = status.next_timestep
 end 

 PlantSimEngine.ObjectDependencyTrait(::Type{<:HelperCurrentTimestepModel}) = PlantSimEngine.IsObjectDependent()
 PlantSimEngine.TimeStepDependencyTrait(::Type{<:HelperCurrentTimestepModel}) = PlantSimEngine.IsTimeStepDependent()

 PlantSimEngine.@process "basic_next_timestep" verbose = false
 struct HelperNextTimestepModel <: AbstractBasic_Next_TimestepModel
 end
 
 PlantSimEngine.inputs_(::HelperNextTimestepModel) = (current_timestep=1,)
 PlantSimEngine.outputs_(m::HelperNextTimestepModel) = (next_timestep=1,)
 
 function PlantSimEngine.run!(m::HelperNextTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
     status.next_timestep = status.current_timestep + 1
  end 

PlantSimEngine.ObjectDependencyTrait(::Type{<:HelperNextTimestepModel}) = PlantSimEngine.IsObjectDependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:HelperNextTimestepModel}) = PlantSimEngine.IsTimeStepDependent()

struct GeneratedStatusVectorModel{V<:AbstractVector} <: AbstractModel
    process_name::Symbol
    output_name::Symbol
    values::V
end

process(model::GeneratedStatusVectorModel) = model.process_name
PlantSimEngine.inputs_(::GeneratedStatusVectorModel) = (current_timestep=1,)
PlantSimEngine.outputs_(model::GeneratedStatusVectorModel) = NamedTuple{(model.output_name,)}((first(model.values),))

function PlantSimEngine.run!(model::GeneratedStatusVectorModel, models, status, meteo, constants=nothing, extra_args=nothing)
    status[model.output_name] = model.values[status.current_timestep]
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:GeneratedStatusVectorModel}) = PlantSimEngine.IsObjectDependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:GeneratedStatusVectorModel}) = PlantSimEngine.IsTimeStepDependent()


# TODO should the new_status be copied ?
# Note : User specifies at which level they want the basic timestep model to be inserted at, as well as the meteo length
function replace_mapping_status_vectors_with_generated_models(mapping_with_vectors_in_status, timestep_model_organ_level, nsteps)
    timestep_model_organ_level = _normalize_scale(
        timestep_model_organ_level;
        warn=timestep_model_organ_level isa AbstractString,
        context=:ModelMapping
    )
    
    (organ, check) = check_statuses_contain_no_remaining_vectors(mapping_with_vectors_in_status)
        if check
        @warn "No vectors, or types deriving from AbstractVector found in statuses, returning mapping as is."
        return mapping_with_vectors_in_status isa ModelMapping ? mapping_with_vectors_in_status : ModelMapping(mapping_with_vectors_in_status)
    end

    # we are now certain a model will be generated, and that the timestep models need to be inserted
    mapping = Dict(
        _normalize_scale(organ; warn=organ isa AbstractString, context=:ModelMapping) => models
        for (organ, models) in mapping_with_vectors_in_status
    )
    for (organ,models) in mapping
        for status in models           
            if isa(status, Status)                
                # Generate models and remove corresponding vectors from status
                new_status, generated_models = generate_model_from_status_vector_variable(mapping, timestep_model_organ_level, status, organ, nsteps)

                # Avoid inserting empty named tuples into the mapping
                models_and_new_status = [model for model in models if !isa(model, Status)]
                if length(new_status) != 0
                    models_and_new_status = [models_and_new_status..., new_status]
                end

                # The timestep models might be inserted elsewhere in the mapping, handle various cases
                if length(generated_models) > 0
                    mapping[organ] = (
                        generated_models...,                          
                        models_and_new_status...,)
                end      
            end         
        end
        
        # insert timestep models wherever they're required
        if organ == timestep_model_organ_level
            # mapping at a given level can be a tuple or a single model
            if isa(mapping[organ], AbstractModel) || isa(mapping[organ], MultiScaleModel) || isa(mapping[organ], ModelSpec)
                mapping[organ] = (
                    HelperNextTimestepModel(),
                    MultiScaleModel(
                    model=HelperCurrentTimestepModel(),
                    mapped_variables=[PreviousTimeStep(:next_timestep),],
                    ),
                    mapping[organ], )
            else
                mapping[organ] = (
                HelperNextTimestepModel(),
                MultiScaleModel(
                model=HelperCurrentTimestepModel(),
                mapped_variables=[PreviousTimeStep(:next_timestep),],
                ),
                mapping[organ]..., )
            end
        end
    end

    return ModelMapping(mapping)
end

function generate_model_from_status_vector_variable(mapping, timestep_scale, status, organ, nsteps)
    timestep_scale = _normalize_scale(timestep_scale; warn=timestep_scale isa AbstractString, context=:ModelMapping)
    organ = _normalize_scale(organ; warn=organ isa AbstractString, context=:ModelMapping)

    # Ah, another point that remains to be seen is that those CSV.SentinelArrays.ChainedVector obtained from the meteo file isn't an AbstractVector
    # meaning currently we won't generate models from them unless the conversion is made before that
    # So another minor potential improvement would be to return a warning to the user and do the conversion when generating the model
    # See the test code in test-mapping.jl : cumsum(meteo_day.TT) returns such a data structure

    generated_models = Any[]
    new_status_names = Symbol[]
    new_status_values = Any[]

    for symbol in keys(status)
        value = getproperty(status, symbol)
        if isa(value, AbstractVector)
            @assert length(value) > 0 "Error during generation of models from vector values provided at the $organ-level status : provided $symbol vector is empty"
            # TODO : Might need to fiddle with timesteps here in the future in case of varying timestep models
            @assert nsteps == length(value) "Error during generation of models from vector values provided at the $organ-level status : provided $symbol vector length doesn't match the expected # of timesteps"

            process_name = Symbol(lowercase(string(symbol) * bytes2hex(sha1(repr(value)))))
            model = GeneratedStatusVectorModel(process_name, symbol, value)

            # if :current_timestep is not in the same scale
            if timestep_scale != organ
                push!(
                    generated_models,
                    MultiScaleModel(
                        model=model,
                        mapped_variables=[:current_timestep => (timestep_scale => :current_timestep)],
                    )
                )
            else
                push!(generated_models, model)
            end
        else
            push!(new_status_names, symbol)
            push!(new_status_values, value)
        end
    end

    new_status = Status(NamedTuple{Tuple(new_status_names)}(Tuple(new_status_values)))
    generated_models_tuple = Tuple(generated_models)

    @assert length(status) == length(new_status) + length(generated_models_tuple) "Error during generation of models from vector values provided at the $organ-level status"
    return new_status, generated_models_tuple
end


# This is a helper function only for testing purposes.
function modellist_to_mapping(modellist_original::ModelList, modellist_status; nsteps=nothing, outputs=nothing)
    
    modellist = Base.copy(modellist_original, modellist_original.status)

    default_scale = :Default
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", default_scale, 0, 0),)

    models = modellist.models

    mapping_incomplete = isnothing(modellist_status) ? 
    (
        Dict(
        default_scale => (
        models..., 
        MultiScaleModel(
        model=HelperCurrentTimestepModel(),
        mapped_variables=[PreviousTimeStep(:next_timestep),],
        ),
        Status((current_timestep=1,next_timestep=1,))
        ),
    )) : (
        Dict(
        default_scale => (
        models..., 
        MultiScaleModel(
        model=HelperCurrentTimestepModel(),
        mapped_variables=[PreviousTimeStep(:next_timestep),],
        ),
        Status((modellist_status..., current_timestep=1,next_timestep=1,))
        ),
    )
    )
    timestep_scale = :Default
    organ = :Default
 
    # todo improve on this
    st = last(mapping_incomplete[:Default])
    new_status, generated_models = generate_model_from_status_vector_variable(mapping_incomplete, timestep_scale, st, organ, nsteps)

    mapping = Dict(default_scale => (
        models..., generated_models..., 
        HelperNextTimestepModel(),
        MultiScaleModel(
            model=HelperCurrentTimestepModel(),
            mapped_variables=[PreviousTimeStep(:next_timestep),],
            ),
            new_status,
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

    return mtg, ModelMapping(mapping), Dict(default_scale => all_vars)
end

function modellist_to_mapping(mapping::ModelMapping{SingleScale}, modellist_status; nsteps=nothing, outputs=nothing)
    modellist_to_mapping(mapping.data, modellist_status; nsteps=nsteps, outputs=outputs)
end

function check_statuses_contain_no_remaining_vectors(mapping)
    for (organ,models) in mapping

        # Special case (scales that map to a single-model don't need to be declared as a tuple for user-convenience)
        if isa(models, AbstractModel) || isa(models, MultiScaleModel) || isa(models, ModelSpec)
            continue
        end

        for status in models
            if isa(status, Status)
                for symbol in keys(status)
                    value = getproperty(status, symbol)
                    if isa(value, AbstractVector)
                        return (organ, false)
                    end
                end
            end
        end
    end
    return (Symbol(""), true)
end
