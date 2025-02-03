# Utilities to handle vectors passed into a mapping's statuses
# This is a convenience when prototyping, not recommended for production or proper fitting
# (Write the actual finalised model explicitely instead)


# The way we generate models from status vectors is to eval() code at runtime.
# A simple custom timestep model provides the correct index to the generated models
# This approach feels a little brittle but works. A (possible ?) improvement would be to directly fiddle with the AST, but it's a little more involved
# Another approach might be to generate a string to be included with include_string, that might avoid awkward global variables and world age problems

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


# TODO should the new_status be copied ?
# Note : User specifies at which level they want the basic timestep model to be inserted at, as well as the meteo length
function replace_mapping_status_vectors_with_generated_models(mapping_with_vectors_in_status, timestep_model_organ_level, nsteps)
    
    (organ, check) = check_statuses_contain_no_remaining_vectors(mapping_with_vectors_in_status)
        if check
        @warn "No vectors, or types deriving from AbstractVector found in statuses, returning mapping as is."
        return mapping_with_vectors_in_status
    end

    # we are now certain a model will be generated, and that the timestep models need to be inserted
    mapping = Dict(organ => models for (organ, models) in mapping_with_vectors_in_status)
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
            if isa(mapping[organ], AbstractModel) || isa(mapping[organ], MultiScaleModel)
                mapping[organ] = (
                    HelperNextTimestepModel(),
                    MultiScaleModel(
                    model=HelperCurrentTimestepModel(),
                    mapping=[PreviousTimeStep(:next_timestep),],
                    ),
                    mapping[organ], )
            else
                mapping[organ] = (
                HelperNextTimestepModel(),
                MultiScaleModel(
                model=HelperCurrentTimestepModel(),
                mapping=[PreviousTimeStep(:next_timestep),],
                ),
                mapping[organ]..., )
            end
        end
    end

    return mapping
end

# Note : eval works in global scope, and state synchronisation doesn't occur until one returns to top-level
# This is to enable optimisations. See 'world-age problem'. The doc for eval currently isn't detailed enough.
# Essentially, generating a struct with a process_ method and then immediately creating a simulation graph
# that calls process_ will fail as it won't yet be defined since state hasn't synchronised. 
# Returning a new mapping to top-level and *then* creating the graph will work.
# The fact that eval works in global scope is also why we make use of some global variables here
function generate_model_from_status_vector_variable(mapping, timestep_scale, status, organ, nsteps)
    
    # Note : 534f1c161f91bb346feba1a84a55e8251f5ad446 is a prefix to reduce likelihood of global variable name conflicts
    # it is the hash generated by bytes2hex(sha1("PlantSimEngine_prototype"))
    # If this function is hard to read, copy it into a temporary file and remove the hash suffix

    # Ah, another point that remains to be seen is that those CSV.SentinelArrays.ChainedVector obtained from the meteo file isn't an AbstractVector
    # meaning currently we won't generate models from them unless the conversion is made before that
    # So another minor potential improvement would be to return a warning to the user and do the conversion when generating the model
    # See the test code in test-mapping.jl : cumsum(meteo_day.TT) returns such a data structure

    global generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446 = ()
    global new_status_534f1c161f91bb346feba1a84a55e8251f5ad446 = Status(NamedTuple())
   
    for symbol in keys(status)
        global value_534f1c161f91bb346feba1a84a55e8251f5ad446 = getproperty(status, symbol)
        if isa(value_534f1c161f91bb346feba1a84a55e8251f5ad446, AbstractVector)
            @assert length(value_534f1c161f91bb346feba1a84a55e8251f5ad446) > 0 "Error during generation of models from vector values provided at the $organ-level status : provided $symbol vector is empty"
            # TODO : Might need to fiddle with timesteps here in the future in case of varying timestep models
            @assert nsteps == length(value_534f1c161f91bb346feba1a84a55e8251f5ad446) "Error during generation of models from vector values provided at the $organ-level status : provided $symbol vector length doesn't match the expected # of timesteps"
            var_type = eltype(value_534f1c161f91bb346feba1a84a55e8251f5ad446)
            base_name = string(symbol) * bytes2hex(sha1(join(value_534f1c161f91bb346feba1a84a55e8251f5ad446)))
            process_name = lowercase(base_name)
  
            var_titlecase::String = titlecase(base_name)
            model_name = "My$(var_titlecase)Model"
            process_abstract_name = "Abstract$(var_titlecase)Model"
            var_vector = "$(symbol)_vector"

            abstract_process_decl = "abstract type $process_abstract_name <: PlantSimEngine.AbstractModel end"
            eval(Meta.parse(abstract_process_decl))
            
            process_name_decl = "PlantSimEngine.process_(::Type{$process_abstract_name}) = :$process_name"
            eval(Meta.parse(process_name_decl))
    
            struct_decl::String = "struct $model_name <: $process_abstract_name \n$var_vector::Vector{$var_type} \nend\n"
            eval(Meta.parse(struct_decl))
            
            inputs_decl::String = "function PlantSimEngine.inputs_(::$model_name)\n(current_timestep=1,)\nend\n"
            eval(Meta.parse(inputs_decl))
    
            default_value = value_534f1c161f91bb346feba1a84a55e8251f5ad446[1]
            outputs_decl::String = "function PlantSimEngine.outputs_(::$model_name)\n($symbol=$default_value,)\nend\n"
            eval(Meta.parse(outputs_decl))
    
            constructor_decl =  "$model_name(; $var_vector = Vector{$var_type}()) = $model_name($var_vector)\n"
            eval(Meta.parse(constructor_decl))
    
            run_decl = "function PlantSimEngine.run!(m::$model_name, models, status, meteo, constants=nothing, extra_args=nothing)\nstatus.$symbol = m.$var_vector[status.current_timestep]\nend\n"
            eval(Meta.parse(run_decl))
    
            model_add_decl = "generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446 = (generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446..., $model_name($var_vector=$value_534f1c161f91bb346feba1a84a55e8251f5ad446),)"

            # if :current_timestep is not in the same scale
            if timestep_scale != organ
                model_add_decl = "generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446 = (generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446..., MultiScaleModel(model=$model_name($value_534f1c161f91bb346feba1a84a55e8251f5ad446), mapping=[:current_timestep=>\"$timestep_scale\"],),)"
            end 
       
        eval(Meta.parse(model_add_decl))
        else
            new_status_decl = "new_status_534f1c161f91bb346feba1a84a55e8251f5ad446 = Status(; NamedTuple(new_status_534f1c161f91bb346feba1a84a55e8251f5ad446)..., $symbol=$value_534f1c161f91bb346feba1a84a55e8251f5ad446)"
            eval(Meta.parse(new_status_decl))
        end
    end
    
    @assert length(status) == length(new_status_534f1c161f91bb346feba1a84a55e8251f5ad446) + length(generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446) "Error during generation of models from vector values provided at the $organ-level status"
    return new_status_534f1c161f91bb346feba1a84a55e8251f5ad446, generated_models_534f1c161f91bb346feba1a84a55e8251f5ad446
end


# This is a helper function only for testing purposes, but it makes sense to include it here since it calls 
# generate_model_from_status_vector_variable, which has those awkward global variables
function modellist_to_mapping(modellist_original::ModelList, modellist_status; nsteps=nothing, outputs=nothing)
    
    modellist = Base.copy(modellist_original, modellist_original.status)

    default_scale = "Default"
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", default_scale, 0, 0),)

    models = modellist.models

    mapping_incomplete = isnothing(modellist_status) ? 
    (
        Dict(
        default_scale => (
        models..., 
        MultiScaleModel(
        model=HelperCurrentTimestepModel(),
        mapping=[PreviousTimeStep(:next_timestep),],
        ),
        Status((current_timestep=1,next_timestep=1,))
        ),
    )) : (
        Dict(
        default_scale => (
        models..., 
        MultiScaleModel(
        model=HelperCurrentTimestepModel(),
        mapping=[PreviousTimeStep(:next_timestep),],
        ),
        Status((modellist_status..., current_timestep=1,next_timestep=1,))
        ),
    )
    )
    timestep_scale = "Default"
    organ = "Default"
 
    # todo improve on this
    st = (last(mapping_incomplete["Default"]))
    new_status, generated_models = generate_model_from_status_vector_variable(mapping_incomplete, timestep_scale, st, organ, nsteps)

    mapping = Dict(default_scale => (
        models..., generated_models..., 
        HelperNextTimestepModel(),
        MultiScaleModel(
            model=HelperCurrentTimestepModel(),
            mapping=[PreviousTimeStep(:next_timestep),],
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

    return mtg, mapping, Dict(default_scale => all_vars)
end

function check_statuses_contain_no_remaining_vectors(mapping)
    for (organ,models) in mapping

        # Special case (scales that map to a single-model don't need to be declared as a tuple for user-convenience)
        if isa(models, AbstractModel) || isa(models, MultiScaleModel)
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
    return ("", true)
end