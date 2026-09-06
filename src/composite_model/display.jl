# Display authored configuration only. Inspecting a model must not compile it,
# initialize its status, sample the environment, or refresh lifecycle caches.
function Base.show(io::IO, model::CompositeModel)
    print(io, "CompositeModel(objects=", length(model.registry.objects),
        ", applications=", length(model.applications))
    isempty(model.instances) || print(io, ", instances=", length(model.instances))
    print(io, ")")
end

function _model_display_line(io::IO, text::AbstractString)
    width = max(1, displaysize(io)[2])
    if textwidth(text) <= width
        print(io, text)
        return
    end
    used = 0
    for character in text
        used + textwidth(character) > width - 1 && break
        print(io, character)
        used += textwidth(character)
    end
    print(io, '…')
end

_model_display_label(value) = escape_string(string(value))

function _model_display_scales(model::CompositeModel)
    by_scale = model.registry.by_scale
    scales = sort!(collect(keys(by_scale)); by=string)
    labels = [
        string(_model_display_label(scale), ": ", length(by_scale[scale]))
        for scale in Iterators.take(scales, 6)
    ]
    length(scales) > 6 && push!(labels, "…")
    unlabelled = length(model.registry.objects) - sum(length, values(by_scale); init=0)
    unlabelled > 0 && push!(labels, string("no scale label: ", unlabelled))
    return join(labels, ", ")
end

function _model_display_environment(environment)
    isnothing(environment) && return "none"
    name = string(nameof(typeof(environment)))
    if environment isa TimeStepTable
        return string(name, " (", length(environment), " rows)")
    end
    return name
end

function _model_display_application(application)
    spec = application isa ModelSpec ? application : nothing
    model = isnothing(spec) ? application : spec.model
    base_model = model isa ObjectModelOverrides ? model.base : model
    label = string(nameof(typeof(base_model)))
    if !isnothing(spec) && !isnothing(spec.name)
        label = string(_model_display_label(spec.name), ": ", label)
    end
    if model isa ObjectModelOverrides
        count = length(model.overrides)
        label *= string(" (", count, " object override", count == 1 ? "" : "s", ")")
    end
    if !isnothing(spec) && !isnothing(spec.timestep)
        cadence = spec.timestep isa Dates.Period ? string(spec.timestep) :
                  string(nameof(typeof(spec.timestep)))
        label *= string("; every ", cadence)
    end
    return label
end

function Base.show(io::IO, ::MIME"text/plain", model::CompositeModel)
    if get(io, :compact, false)
        show(io, model)
        return
    end
    _model_display_line(io, "CompositeModel")
    scales = _model_display_scales(model)
    objects = string("  Objects: ", length(model.registry.objects))
    isempty(scales) || (objects *= string(" (", scales, ")"))
    print(io, '\n')
    _model_display_line(io, objects)
    if !isempty(model.instances)
        print(io, '\n')
        _model_display_line(io, string("  Template instances: ", length(model.instances)))
    end
    print(io, '\n')
    _model_display_line(io, string("  Shared environment: ", _model_display_environment(model.environment)))
    print(io, '\n')
    _model_display_line(io, string("  Model applications: ", length(model.applications)))

    # This is a summary even when :limit is false. In a small terminal, leave
    # room for the header and the number of omitted applications.
    header_lines = isempty(model.instances) ? 4 : 5
    available = get(io, :limit, false) ? max(0, displaysize(io)[1] - header_lines - 1) : 8
    shown = min(length(model.applications), 8, available)
    for application in Iterators.take(model.applications, shown)
        print(io, '\n')
        _model_display_line(io, string("    ", _model_display_application(application)))
    end
    remaining = length(model.applications) - shown
    if remaining > 0
        print(io, '\n')
        _model_display_line(io, string("    … ", remaining, " more"))
    end
end
