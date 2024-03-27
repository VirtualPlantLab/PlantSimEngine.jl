function status_template2(mapping::Dict{String}, type_promotion; verbose=false)

    mapped_vars = mapped_variables(mapping, dep(mapping), verbose=verbose)

    # Update the types of the variables as desired by the user:
    convert_variable_types!(mapped_vars, type_promotion)

    #! continue here

    # organs_statuses_dict = Dict{String,Dict{Symbol,Any}}()
    # dict_mapped_vars = Dict{Pair,Any}()

    for organ in keys(mapping) # e.g.: organ = "Internode"
        # Parsing the models into a NamedTuple to get the process name:
        node_models = parse_models(get_models(mapping[organ]))

        # Get the status if any was given by the user (this can be used as default values in the mapping):
        st = get_status(mapping[organ]) # User status

        if isnothing(st)
            st = NamedTuple()
        else
            st = NamedTuple(st)
        end

        # Add the variables that are defined as multiscale (coming from other scales):
        if haskey(organs_mapping, organ)
            st_vars_mapped = (; zip(vars_from_mapping(organs_mapping[organ]), vars_type_from_mapping(organs_mapping[organ]))...)
            !isnothing(st_vars_mapped) && (st = merge(st, st_vars_mapped))
        end

        # Add the variable(s) written by other scales into this node scale:
        haskey(var_outputs_from_mapping, organ) && (st = merge(st, var_outputs_from_mapping[organ]))

        # Then we initialise a status taking into account the status given by the user.
        # This step is done to get default values for each variables:
        if length(st) == 0
            st = nothing
        else
            st = Status(st)
        end

        st = add_model_vars(st, node_models, type_promotion; init_fun=x -> Status(x))

        # For the variables that are RefValues of other variables at a different scale, we need to actually create a reference to this variable
        # in the status. So we replace the RefValue by a RefValue to the actual variable, and instantiate a Status directly with the actual Refs.
        val_pointers = Dict{Symbol,Any}(zip(keys(st), values(st)))
        if any(x -> isa(x, MappedVar), values(st))
            for (k, v) in val_pointers # e.g.: k = :soil_water_content; v = val_pointers[k]
                if isa(v, MappedVar)
                    # First time we encounter this variable as a MappedVar, we create its value into the dict_mapped_vars Dict:
                    if !haskey(dict_mapped_vars, v.organ => v.var)
                        push!(dict_mapped_vars, Pair(v.organ, v.var) => Ref(st[k].default))
                    end

                    # Then we replace the MappedVar by a RefValue to the actual variable:
                    val_pointers[k] = dict_mapped_vars[v.organ=>v.var]
                else
                    val_pointers[k] = st[k]
                end
            end
        end
        organs_statuses_dict[organ] = val_pointers
    end

    return organs_statuses_dict
end