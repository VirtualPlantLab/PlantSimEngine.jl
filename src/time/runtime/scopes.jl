const _BUILTIN_SCOPE_SELECTORS = (:global, :plant, :scene, :self)

"""
    _model_spec_for_process(sim, scale, process)

Return the normalized `ModelSpec` for one `(scale, process)` pair.
"""
function _model_spec_for_process(sim::GraphSimulation, scale::String, process::Symbol)
    specs_at_scale = get_model_specs(sim)[scale]
    if haskey(specs_at_scale, process)
        return specs_at_scale[process]
    end

    models_at_scale = get_models(sim)[scale]
    haskey(models_at_scale, process) || error(
        "Cannot resolve model spec for process `$(process)` at scale `$(scale)`."
    )
    return as_model_spec(models_at_scale[process])
end

function _find_ancestor_by_symbol(node, target::Symbol)
    current = node
    while !isnothing(current)
        symbol(current) == target && return current
        current = parent(current)
    end
    return nothing
end
_find_ancestor_by_symbol(node, target::AbstractString) = _find_ancestor_by_symbol(node, Symbol(target))

function _scope_from_builtin(selector::Symbol, node, scale::String, process::Symbol)
    if selector == :global
        return ScopeId(:global, 1)
    elseif selector == :self
        return ScopeId(:self, node_id(node))
    elseif selector == :plant
        plant = _find_ancestor_by_symbol(node, :Plant)
        isnothing(plant) && error(
            "Scope selector `:plant` for process `$(process)` at scale `$(scale)` ",
            "could not find a `Plant` ancestor for node `$(node_id(node))`."
        )
        return ScopeId(:plant, node_id(plant))
    elseif selector == :scene
        scene = _find_ancestor_by_symbol(node, :Scene)
        isnothing(scene) && error(
            "Scope selector `:scene` for process `$(process)` at scale `$(scale)` ",
            "could not find a `Scene` ancestor for node `$(node_id(node))`."
        )
        return ScopeId(:scene, node_id(scene))
    end

    error(
        "Unsupported scope selector `$(selector)` for process `$(process)` at scale `$(scale)`. ",
        "Supported selectors are $(_BUILTIN_SCOPE_SELECTORS), `ScopeId`, or a callable."
    )
end

function _scope_from_selector_result(result, node, scale::String, process::Symbol)
    if result isa ScopeId
        return result
    elseif result isa Symbol
        return _scope_from_builtin(result, node, scale, process)
    elseif result isa AbstractString
        return _scope_from_builtin(Symbol(result), node, scale, process)
    end

    error(
        "Scope selector for process `$(process)` at scale `$(scale)` must return `ScopeId`, `Symbol`, or `String`, ",
        "got `$(typeof(result))`."
    )
end

function _scope_from_selector(selector, node, scale::String, process::Symbol)
    if selector isa ScopeId
        return selector
    elseif selector isa Symbol
        return _scope_from_builtin(selector, node, scale, process)
    elseif selector isa AbstractString
        return _scope_from_builtin(Symbol(selector), node, scale, process)
    elseif selector isa Function
        result = if applicable(selector, node, scale, process)
            selector(node, scale, process)
        elseif applicable(selector, node, scale)
            selector(node, scale)
        elseif applicable(selector, node)
            selector(node)
        else
            error(
                "Scope callable for process `$(process)` at scale `$(scale)` must accept `(node)`, `(node, scale)` ",
                "or `(node, scale, process)`."
            )
        end
        return _scope_from_selector_result(result, node, scale, process)
    end

    error(
        "Unsupported scope selector type `$(typeof(selector))` for process `$(process)` at scale `$(scale)`."
    )
end

"""
    _scope_for_status(sim, model_spec, scale, process, node)

Resolve the effective `ScopeId` for one node status and one model process.
"""
function _scope_for_status(sim::GraphSimulation, model_spec, scale::String, process::Symbol, node)
    selector = isnothing(model_spec) ? :global : model_scope(model_spec)
    return _scope_from_selector(selector, node, scale, process)
end
