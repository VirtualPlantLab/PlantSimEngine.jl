
"""
    convert_variable_types!(mapped_vars::Dict{String,Dict{String,Any}}, type_promotion)

Converts the types of the variables in `mapped_vars` using the `type_promotion` dictionary.
See `convert_vars!` for more details.
"""
function convert_variable_types!(mapped_vars::Dict{String,Dict{String,Any}}, type_promotion)
    for (organ, vars) in mapped_vars
        convert_vars!(type_promotion, vars)
    end
end