"""
    _symbol_from_dependency_var(x)

Extract a symbol variable name from dependency graph variable descriptors
(`Symbol`, `PreviousTimeStep`, `MappedVar`).
"""
function _symbol_from_dependency_var(x)
    if x isa Symbol
        return x
    elseif x isa PreviousTimeStep
        return x.variable
    elseif x isa MappedVar
        mv = mapped_variable(x)
        return mv isa PreviousTimeStep ? mv.variable : mv
    else
        return nothing
    end
end

"""
    _push_candidate_producer!(candidates, process_key, vars, input_var)

Append producer candidates `(process, input_var)` when `vars` contains
`input_var`.
"""
function _push_candidate_producer!(candidates::Vector{Tuple{Symbol,Symbol}}, process_key, vars, input_var::Symbol)
    process = Symbol(process_key)
    for v in vars
        s = _symbol_from_dependency_var(v)
        isnothing(s) && continue
        if s == input_var
            push!(candidates, (process, input_var))
        end
    end
end

"""
    _collect_candidate_producers!(candidates, parent_vars, input_var)

Recursively collect candidate producers from nested dependency metadata.
"""
function _collect_candidate_producers!(candidates::Vector{Tuple{Symbol,Symbol}}, parent_vars::NamedTuple, input_var::Symbol)
    for (k, v) in pairs(parent_vars)
        if v isa NamedTuple
            _collect_candidate_producers!(candidates, v, input_var)
        elseif v isa Tuple || v isa AbstractVector
            _push_candidate_producer!(candidates, k, v, input_var)
        end
    end
end

"""
    _candidate_producers(node, input_var)

Return unique `(process, var)` producer candidates for `input_var` from the
soft-dependency parents of `node`.
"""
function _candidate_producers(node::SoftDependencyNode, input_var::Symbol)
    node.parent_vars === nothing && return Tuple{Symbol,Symbol}[]
    c = Tuple{Symbol,Symbol}[]
    _collect_candidate_producers!(c, node.parent_vars, input_var)
    unique(c)
end

"""
    _parse_input_binding(binding)

Normalize one `InputBindings` entry to `(process, var, scale, policy)`.
Accepts shorthand forms (`Symbol`, `Pair{Symbol,Symbol}`, `NamedTuple`).
"""
function _parse_input_binding(binding)
    if binding isa Symbol
        return (process=binding, var=nothing, scale=nothing, policy=HoldLast())
    elseif binding isa Pair{Symbol,Symbol}
        return (process=first(binding), var=last(binding), scale=nothing, policy=HoldLast())
    elseif binding isa NamedTuple
        process = haskey(binding, :process) ? binding.process : nothing
        var = haskey(binding, :var) ? binding.var : nothing
        scale = haskey(binding, :scale) ? string(binding.scale) : nothing
        policy = haskey(binding, :policy) ? binding.policy : HoldLast()
        if policy isa DataType && policy <: SchedulePolicy
            policy = policy()
        end
        return (process=process, var=var, scale=scale, policy=policy)
    else
        return nothing
    end
end

"""
    _source_scale_for_process(node, process)

Resolve the scale of a producer process from the current node parent links.
Falls back to the current node scale when no explicit parent match exists.
"""
function _source_scale_for_process(node::SoftDependencyNode, process::Symbol)
    if node.parent !== nothing
        for p in node.parent
            if p.process == process
                return p.scale
            end
        end
    end
    return node.scale
end
