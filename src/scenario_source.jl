"""
    scenario_source(model::CompositeModel; environments=Dict{Symbol,Any}())

Return Julia source that reconstructs `model` as a variable named `model`.

`environments` is an optional symbol-keyed catalog of runtime environment
values. Catalog values are referenced by identity in the generated source as
`scenario_environments.<name>` instead of being serialized. The generated source
records the required catalog names in a leading comment so callers can check
them before evaluation.

The source preserves model objects, object-local applications, templates,
instances, model and object overrides, application configuration, effective
status values, and safely reconstructible status-conversion policies. Values
that cannot be represented safely are described with `# WARNING:` comments in
the generated source.
"""
function scenario_source(
    model::CompositeModel;
    environments=Dict{Symbol,Any}(),
)
    environment_catalog = _scenario_source_environment_catalog(environments)
    io = IOBuffer()
    diagnostics = String[]
    status_conversion = _scenario_source_status_conversion_policy_code(
        model,
        diagnostics,
    )
    status_conversion_records = isnothing(status_conversion) ?
                                nothing :
                                _scenario_source_status_conversion_records_code(
        model,
        diagnostics,
    )
    modules = _scenario_source_model_modules(model)
    for module_name in sort!(collect(modules))
        println(io, "using $(module_name)")
    end
    println(io, "using Dates")
    println(io)

    if !isnothing(model.source_adapter)
        push!(
            diagnostics,
            "The Composite model source_adapter is runtime-specific and is not reconstructed by generated code.",
        )
    end
    for process_model in _scenario_source_models(model)
        Base.moduleroot(parentmodule(typeof(process_model))) === Main || continue
        push!(
            diagnostics,
            "Model $(typeof(process_model)) is defined in Main. Define or include that model before evaluating this generated Composite model script.",
        )
    end
    for diagnostic in unique(diagnostics)
        println(io, "# WARNING: ", diagnostic)
    end
    required_environments = _scenario_source_required_environment_names(
        model,
        environment_catalog,
    )
    if !isempty(required_environments)
        names = join(sort!(string.(collect(required_environments))), ", ")
        println(io, "# Requires `scenario_environments` with named values: ", names, ".")
    end
    isempty(diagnostics) || println(io)

    println(io, "objects = (")
    for object in model_objects(model)
        println(
            io,
            "    ",
            _scenario_source_object_code(environment_catalog, object),
            ",",
        )
    end
    println(io, ")")

    templates = Any[]
    for instance in model.instances
        any(template -> template === instance.template, templates) ||
            push!(templates, instance.template)
    end
    for (index, template) in pairs(templates)
        println(io)
        println(
            io,
            "template_$(index) = ",
            _scenario_source_template_code(environment_catalog, template),
        )
    end

    println(io)
    if !isempty(model.instances)
        println(io, "instances = (")
        for instance in model.instances
            template_index = only(
                index for (index, template) in pairs(templates)
                if template === instance.template
            )
            println(
                io,
                "    ",
                _scenario_source_instance_code(instance, template_index),
                ",",
            )
        end
        println(io, ")")
    else
        println(io, "instances = ()")
    end

    mounted_ids = Set{Symbol}()
    for instance in model.instances
        union!(mounted_ids, _instance_application_ids(model, instance))
    end
    global_applications = [
        application for application in model.applications
        if _model_edit_application_id(application) ∉ mounted_ids
    ]
    println(io, "applications = (")
    for application in global_applications
        println(
            io,
            "    ",
            _scenario_source_application_code(
                environment_catalog,
                as_model_spec(application),
            ),
            ",",
        )
    end
    println(io, ")")

    environment = _scenario_source_environment_value_code(
        environment_catalog,
        model.environment,
    )
    options = String[
        "applications=applications",
        "instances=instances",
        "environment=$(environment)",
    ]
    if !isnothing(status_conversion)
        push!(options, "_status_conversion=$(status_conversion)")
        push!(options, "_status_values_materialized=true")
        isnothing(status_conversion_records) || push!(
            options,
            "_status_conversion_records=$(status_conversion_records)",
        )
    end
    print(io, "model = CompositeModel(objects...; $(join(options, ", ")))")
    return String(take!(io))
end

function _scenario_source_environment_catalog(catalog)
    entries = if catalog isa NamedTuple
        pairs(catalog)
    elseif catalog isa AbstractDict
        pairs(catalog)
    else
        error("Environment catalog must be a NamedTuple or dictionary.")
    end
    normalized = Dict{Symbol,Any}()
    for (name, value) in entries
        name isa Symbol || error(
            "Environment catalog names must be symbols, got `$(repr(name))`.",
        )
        Base.isidentifier(String(name)) || error(
            "Environment catalog name `$(name)` must be a valid Julia identifier.",
        )
        haskey(normalized, name) && error(
            "Environment catalog contains duplicate name `$(name)`.",
        )
        normalized[name] = value
    end
    return normalized
end

function _scenario_source_required_environment_names(model, environment_catalog)
    names = Set{Symbol}()
    add_value = function (value)
        for (name, environment) in environment_catalog
            environment === value && push!(names, name)
        end
    end
    add_value(model.environment)
    add_spec = function (raw_spec)
        spec = as_model_spec(raw_spec)
        environment = environment_config(spec)
        isnothing(environment) && return
        payload = environment isa EnvironmentConfig ? environment.config : environment
        payload isa NamedTuple && haskey(payload, :backend) && add_value(payload.backend)
    end
    foreach(add_spec, model.applications)
    for object in model_objects(model)
        isnothing(object.applications) || foreach(add_spec, object.applications)
    end
    for instance in model.instances
        foreach(add_spec, instance.template.applications)
    end
    return names
end

function _scenario_source_models(model)
    models = Any[]
    add_application = function (application)
        process_model = model_(as_model_spec(application))
        if process_model isa ObjectModelOverrides
            push!(models, process_model.base)
            append!(models, values(process_model.overrides))
        else
            push!(models, process_model)
        end
    end
    foreach(add_application, model.applications)
    for object in model_objects(model)
        isnothing(object.applications) && continue
        foreach(add_application, object.applications)
    end
    for instance in model.instances
        foreach(add_application, instance.template.applications)
        append!(models, values(instance.overrides))
        append!(models, (override.model for override in instance.object_overrides))
    end
    return models
end

function _scenario_source_model_modules(model)
    modules = Set{String}(["PlantSimEngine"])
    add_model = function (process_model)
        module_ = parentmodule(typeof(process_model))
        module_ in (Base, Core, Main) || push!(modules, string(module_))
    end
    foreach(add_model, _scenario_source_models(model))
    return modules
end

function _scenario_source_object_code(environment_catalog, object)
    keywords = String[
        "scale=$(repr(object.scale))",
        "kind=$(repr(object.kind))",
        "species=$(repr(object.species))",
        "name=$(repr(object.name))",
        "parent=$(isnothing(object.parent) ? "nothing" : repr(object.parent.value))",
    ]
    if object.status isa Status
        values = join(
            (
                "$(name)=$(repr(object.status[name]))"
                for name in propertynames(object.status)
            ),
            ", ",
        )
        push!(keywords, "status=Status(; $(values))")
    end
    isnothing(object.geometry) || push!(keywords, "geometry=$(repr(object.geometry))")
    if !isnothing(object.applications) && object.applications != ()
        applications = join(
            (
                _scenario_source_application_code(
                    environment_catalog,
                    as_model_spec(application),
                ) for application in object.applications
            ),
            ", ",
        )
        push!(keywords, "applications=($(applications),)")
    end
    return "Object($(repr(object.id.value)); $(join(keywords, ", ")))"
end

function _scenario_source_template_code(environment_catalog, template)
    applications = join(
        (
            "        " * _scenario_source_application_code(
                environment_catalog,
                as_model_spec(application),
            ) * "," for application in template.applications
        ),
        "\n",
    )
    return "CompositeModelTemplate((\n$(applications)\n    ); kind=$(repr(template.kind)), species=$(repr(template.species)), parameters=$(repr(template.parameters)))"
end

function _scenario_source_instance_code(instance, template_index)
    overrides = if isempty(keys(instance.overrides))
        "NamedTuple()"
    else
        entries = join(
            ("$(key)=$(repr(model))" for (key, model) in pairs(instance.overrides)),
            ", ",
        )
        "($(entries),)"
    end
    object_overrides = if isempty(instance.object_overrides)
        "()"
    else
        entries = join(
            (_scenario_source_object_override_code(override) for override in instance.object_overrides),
            ", ",
        )
        "($(entries),)"
    end
    return "ObjectInstance($(repr(instance.name)), template_$(template_index); root=$(repr(_instance_root_id(instance).value)), overrides=$(overrides), object_overrides=$(object_overrides))"
end

function _scenario_source_object_override_code(override)
    options = String["object=$(repr(override.object.value))"]
    isnothing(override.application) ||
        push!(options, "application=$(repr(override.application))")
    push!(options, "model=$(repr(override.model))")
    return "Override(; $(join(options, ", ")))"
end

function _scenario_source_environment_value_code(environment_catalog, value)
    isnothing(value) && return "nothing"
    for (name, environment) in environment_catalog
        environment === value && return "scenario_environments.$(name)"
    end
    return repr(value)
end

function _scenario_source_environment_configuration_code(environment_catalog, payload)
    payload isa NamedTuple || return repr(payload)
    entries = String[]
    for (name, value) in pairs(payload)
        code = Symbol(name) == :backend ?
               _scenario_source_environment_value_code(environment_catalog, value) :
               repr(value)
        push!(entries, "$(name)=$(code)")
    end
    return isempty(entries) ? "NamedTuple()" : "($(join(entries, ", ")),)"
end

function _scenario_source_application_code(environment_catalog, spec)
    options = String["name=$(repr(application_name(spec)))"]
    selector = applies_to(spec)
    isnothing(selector) || push!(options, "on=$(repr(selector))")
    isempty(keys(value_inputs(spec))) ||
        push!(options, "inputs=$(repr(value_inputs(spec)))")
    isempty(keys(model_calls(spec))) ||
        push!(options, "calls=$(repr(model_calls(spec)))")
    environment = environment_config(spec)
    if !isnothing(environment)
        payload = environment isa EnvironmentConfig ? environment.config : environment
        push!(
            options,
            "environment=Environment($(_scenario_source_environment_configuration_code(environment_catalog, payload)))",
        )
    end
    isnothing(spec.timestep) || push!(options, "every=$(repr(spec.timestep))")
    if !isempty(keys(environment_bindings(spec)))
        push!(
            options,
            "environment_bindings=$(repr(environment_bindings(spec)))",
        )
    end
    if !isnothing(environment_window(spec))
        push!(options, "environment_window=$(repr(environment_window(spec)))")
    end
    isempty(keys(output_routing(spec))) ||
        push!(options, "output_routing=$(repr(output_routing(spec)))")
    update_codes = String[]
    for update in updates(spec)
        variables = join(repr.(collect(update.variables)), ", ")
        push!(update_codes, "Updates($(variables); after=$(repr(update.after)))")
    end
    if length(update_codes) == 1
        push!(options, "updates=$(only(update_codes))")
    elseif !isempty(update_codes)
        push!(options, "updates=($(join(update_codes, ", ")),)")
    end
    return "ModelSpec($(repr(model_(spec))); $(join(options, ", ")))"
end

function _scenario_source_status_conversion_module_code(module_::Module)
    label = string(module_)
    all(Base.isidentifier, split(label, '.')) || return nothing
    return label
end

function _scenario_source_status_conversion_type_code(type_)
    type_ isa DataType || return nothing
    name = String(nameof(type_))
    Base.isidentifier(name) || return nothing
    occursin('#', name) && return nothing
    module_ = parentmodule(type_)
    module_code = _scenario_source_status_conversion_module_code(module_)
    isnothing(module_code) && return nothing
    isdefined(module_, Symbol(name)) || return nothing
    getfield(module_, Symbol(name)) === type_.name.wrapper || return nothing
    base = module_ in (Base, Core) ? name : "$(module_code).$(name)"
    isempty(type_.parameters) && return base
    parameter_codes = String[]
    for parameter in type_.parameters
        code = parameter isa Type ?
               _scenario_source_status_conversion_type_code(parameter) :
               _scenario_source_status_conversion_literal_code(parameter)
        isnothing(code) && return nothing
        push!(parameter_codes, code)
    end
    return "$(base){$(join(parameter_codes, ", "))}"
end

function _scenario_source_status_conversion_tuple_code(codes::Vector{String})
    isempty(codes) && return "()"
    length(codes) == 1 && return "($(only(codes)),)"
    return "($(join(codes, ", ")))"
end

function _scenario_source_status_conversion_array_code(value::Array)
    element_type = _scenario_source_status_conversion_type_code(eltype(value))
    isnothing(element_type) && return nothing
    elements = String[]
    for item in value
        code = _scenario_source_status_conversion_literal_code(item)
        isnothing(code) && return nothing
        push!(elements, code)
    end
    vector = "$(element_type)[$(join(elements, ", "))]"
    ndims(value) == 1 && return vector
    ndims(value) == 0 && return "reshape($(vector), ())"
    return "reshape($(vector), $(join(size(value), ", ")))"
end

function _scenario_source_status_conversion_literal_code(value)
    value === nothing && return "nothing"
    value === missing && return "missing"
    value isa Type && return _scenario_source_status_conversion_type_code(value)
    if value isa ObjectId
        identifier = _scenario_source_status_conversion_literal_code(value.value)
        isnothing(identifier) && return nothing
        return "PlantSimEngine.ObjectId($(identifier))"
    end
    value isa Union{Bool,Integer,Float16,Float32,Float64,Char,AbstractString,Symbol} &&
        return repr(value)
    if value isa Pair
        first_code = _scenario_source_status_conversion_literal_code(first(value))
        last_code = _scenario_source_status_conversion_literal_code(last(value))
        (isnothing(first_code) || isnothing(last_code)) && return nothing
        return "$(first_code) => $(last_code)"
    end
    if value isa NamedTuple
        names_code = _scenario_source_status_conversion_literal_code(Tuple(keys(value)))
        values_code = _scenario_source_status_conversion_literal_code(Tuple(values(value)))
        (isnothing(names_code) || isnothing(values_code)) && return nothing
        return "NamedTuple{$(names_code)}($(values_code))"
    end
    if value isa Tuple
        codes = String[]
        for item in value
            code = _scenario_source_status_conversion_literal_code(item)
            isnothing(code) && return nothing
            push!(codes, code)
        end
        return _scenario_source_status_conversion_tuple_code(codes)
    end
    value isa Array && return _scenario_source_status_conversion_array_code(value)
    return nothing
end

function _scenario_source_status_transform_code(transform)
    isnothing(transform) && return "nothing"
    try
        Meta.parse(repr(transform))
    catch
        return nothing
    end

    transform_type = typeof(transform)
    type_name = String(nameof(transform_type))
    (Base.isidentifier(type_name) && !occursin('#', type_name)) || return nothing
    if transform isa Function
        name = nameof(transform)
        module_ = parentmodule(transform_type)
        module_code = _scenario_source_status_conversion_module_code(module_)
        isnothing(module_code) && return nothing
        isdefined(module_, name) || return nothing
        getfield(module_, name) === transform || return nothing
        return "$(module_code).$(name)"
    end

    type_code = _scenario_source_status_conversion_type_code(transform_type)
    isnothing(type_code) && return nothing
    fields = Any[
        getfield(transform, index) for index in 1:fieldcount(transform_type)
    ]
    field_codes = String[]
    for field in fields
        code = _scenario_source_status_conversion_literal_code(field)
        isnothing(code) && return nothing
        push!(field_codes, code)
    end
    applicable(transform_type, fields...) || return nothing
    reconstructed = try
        transform_type(fields...)
    catch
        return nothing
    end
    typeof(reconstructed) === transform_type || return nothing
    all(
        isequal(getfield(reconstructed, index), getfield(transform, index))
        for index in 1:fieldcount(transform_type)
    ) || return nothing
    return "$(type_code)($(join(field_codes, ", ")))"
end

function _scenario_source_status_conversion_policy_code(model, diagnostics)
    policy = model.status_conversion
    isempty(policy.rules) && isnothing(policy.transform) && return nothing

    rule_codes = String[]
    mapping_safe = true
    for rule in policy.rules
        source = _scenario_source_status_conversion_type_code(first(rule))
        target = _scenario_source_status_conversion_type_code(last(rule))
        if isnothing(source) || isnothing(target)
            mapping_safe = false
            break
        end
        push!(rule_codes, "$(source) => $(target)")
    end
    if !mapping_safe
        empty!(rule_codes)
        push!(
            diagnostics,
            "The Composite model type_promotion rules are not reconstructed because at least one mapped type has no safe Julia representation. Existing effective Status values are preserved, but future status materialization will not apply the mapping.",
        )
    end
    sort!(rule_codes)

    transform_code = _scenario_source_status_transform_code(policy.transform)
    if isnothing(transform_code)
        transform_repr = replace(repr(policy.transform), '\n' => ' ')
        push!(
            diagnostics,
            "The Composite model status_transform `$(transform_repr)` is not reconstructed because its repr is not a safely reconstructible named function or functor. Existing effective Status values are preserved, but future defaults and registered objects use only reconstructible type_promotion rules.",
        )
        transform_code = "nothing"
    elseif !isnothing(policy.transform) &&
           Base.moduleroot(parentmodule(typeof(policy.transform))) === Main
        push!(
            diagnostics,
            "The Composite model status_transform type $(typeof(policy.transform)) is defined in Main. Define or include it before evaluating this generated Composite model script.",
        )
    end

    rules = _scenario_source_status_conversion_tuple_code(rule_codes)
    return "PlantSimEngine.StatusConversionPolicy($(rules), $(transform_code))"
end

function _scenario_source_status_conversion_record_code(record)
    record isa StatusConversionRecord || return nothing
    arguments = String[]
    for field in fieldnames(typeof(record))
        code = _scenario_source_status_conversion_literal_code(getfield(record, field))
        isnothing(code) && return nothing
        push!(arguments, code)
    end
    return "PlantSimEngine.StatusConversionRecord($(join(arguments, ", ")))"
end

function _scenario_source_status_conversion_records_code(model, diagnostics)
    isempty(model.status_conversion_records) && return nothing
    entries = String[]
    for (key, record) in model.status_conversion_records
        key_code = _scenario_source_status_conversion_literal_code(key)
        record_code = _scenario_source_status_conversion_record_code(record)
        if isnothing(key_code) || isnothing(record_code)
            push!(
                diagnostics,
                "The Composite model status-conversion records contain a value with no safe Julia representation. Generated code omits those diagnostic records while preserving effective Status values and the reconstructible policy.",
            )
            return nothing
        end
        push!(entries, "$(key_code) => $(record_code)")
    end
    sort!(entries)
    return "Dict{Any,Any}($(join(entries, ", ")))"
end
