const _TIMESTEP_HINT_FIELDS = (:required, :preferred)

"""
    timestep_hint(model::AbstractModel)
    timestep_hint(::Type{<:AbstractModel})

Optional model trait used to declare runtime compatibility constraints when
`ModelSpec.timestep` is not provided.

Supported return values:
- `nothing` (default): no hint
- `Dates.FixedPeriod`: fixed required timestep
- `(min_period, max_period)`: required timestep range (`Dates.FixedPeriod` pair)
- `NamedTuple`: with `required` (one of the forms above) and optional `preferred`
  (`:finest`, `:coarsest`, or a `Dates.FixedPeriod` within the required range).
  `preferred` is informational only when runtime derives timestep from meteo.
"""
timestep_hint(model::AbstractModel) = timestep_hint(typeof(model))
timestep_hint(::Type{<:AbstractModel}) = nothing

"""
    meteo_hint(model::AbstractModel)
    meteo_hint(::Type{<:AbstractModel})

Optional model trait used to infer weather sampling when `ModelSpec` does not provide
`MeteoBindings(...)` and/or `MeteoWindow(...)`.

Expected return value is a `NamedTuple` with optional fields:
- `bindings`: compatible with `MeteoBindings(...)`
- `window`: compatible with `MeteoWindow(...)`
"""
meteo_hint(model::AbstractModel) = meteo_hint(typeof(model))
meteo_hint(::Type{<:AbstractModel}) = nothing

struct _ResolvedTimeStepHint
    fixed::Union{Nothing,Dates.FixedPeriod}
    range::Union{Nothing,Tuple{Dates.FixedPeriod,Dates.FixedPeriod}}
    preferred::Union{Nothing,Symbol,Dates.FixedPeriod}
end

_seconds_from_period(p::Dates.FixedPeriod) = float(Dates.value(Dates.Millisecond(p))) * 1.0e-3

function _normalize_required_timestep_hint(scale::Symbol, process::Symbol, required)
    if required isa Dates.FixedPeriod
        _seconds_from_period(required) > 0.0 || error(
            "Invalid `timestep_hint` required period for process `$(process)` at scale `$(scale)`: ",
            "period must be > 0, got `$(required)`."
        )
        return required, nothing
    elseif required isa Tuple
        length(required) == 2 || error(
            "Invalid `timestep_hint` required tuple for process `$(process)` at scale `$(scale)`: ",
            "expected `(min_period, max_period)`."
        )
        minp, maxp = required
        minp isa Dates.FixedPeriod || error(
            "Invalid `timestep_hint` min period for process `$(process)` at scale `$(scale)`: ",
            "expected `Dates.FixedPeriod`, got `$(typeof(minp))`."
        )
        maxp isa Dates.FixedPeriod || error(
            "Invalid `timestep_hint` max period for process `$(process)` at scale `$(scale)`: ",
            "expected `Dates.FixedPeriod`, got `$(typeof(maxp))`."
        )
        min_sec = _seconds_from_period(minp)
        max_sec = _seconds_from_period(maxp)
        min_sec > 0.0 || error(
            "Invalid `timestep_hint` range lower bound for process `$(process)` at scale `$(scale)`: ",
            "period must be > 0, got `$(minp)`."
        )
        max_sec > 0.0 || error(
            "Invalid `timestep_hint` range upper bound for process `$(process)` at scale `$(scale)`: ",
            "period must be > 0, got `$(maxp)`."
        )
        min_sec <= max_sec || error(
            "Invalid `timestep_hint` range for process `$(process)` at scale `$(scale)`: ",
            "lower bound `$(minp)` must be <= upper bound `$(maxp)`."
        )
        return nothing, (minp, maxp)
    end

    error(
        "Invalid `timestep_hint` required value for process `$(process)` at scale `$(scale)`: ",
        "expected `Dates.FixedPeriod` or `(Dates.FixedPeriod, Dates.FixedPeriod)`, got `$(typeof(required))`."
    )
end

function _normalize_timestep_hint(scale::Symbol, process::Symbol, hint)
    isnothing(hint) && return _ResolvedTimeStepHint(nothing, nothing, nothing)

    if hint isa Dates.FixedPeriod || hint isa Tuple
        fixed, range = _normalize_required_timestep_hint(scale, process, hint)
        return _ResolvedTimeStepHint(fixed, range, nothing)
    elseif hint isa NamedTuple
        extra = setdiff(collect(keys(hint)), collect(_TIMESTEP_HINT_FIELDS))
        isempty(extra) || error(
            "Invalid `timestep_hint` for process `$(process)` at scale `$(scale)`: ",
            "unsupported fields $(extra)."
        )
        haskey(hint, :required) || error(
            "Invalid `timestep_hint` for process `$(process)` at scale `$(scale)`: ",
            "field `required` is mandatory when using NamedTuple form."
        )
        fixed, range = _normalize_required_timestep_hint(scale, process, hint.required)
        preferred = haskey(hint, :preferred) ? hint.preferred : nothing
        if !isnothing(preferred)
            if preferred isa Symbol
                preferred in (:finest, :coarsest) || error(
                    "Invalid `timestep_hint.preferred` for process `$(process)` at scale `$(scale)`: ",
                    "supported symbols are `:finest` and `:coarsest`."
                )
            elseif preferred isa Dates.FixedPeriod
                _seconds_from_period(preferred) > 0.0 || error(
                    "Invalid `timestep_hint.preferred` for process `$(process)` at scale `$(scale)`: ",
                    "period must be > 0, got `$(preferred)`."
                )
                if !isnothing(range)
                    lo, hi = range
                    preferred_sec = _seconds_from_period(preferred)
                    lo_sec = _seconds_from_period(lo)
                    hi_sec = _seconds_from_period(hi)
                    lo_sec <= preferred_sec <= hi_sec || error(
                        "Invalid `timestep_hint.preferred=$(preferred)` for process `$(process)` at scale `$(scale)`: ",
                        "preferred period must be inside required range `($(lo), $(hi))`."
                    )
                elseif !isnothing(fixed)
                    _seconds_from_period(preferred) == _seconds_from_period(fixed) || error(
                        "Invalid `timestep_hint.preferred=$(preferred)` for process `$(process)` at scale `$(scale)`: ",
                        "when `required` is fixed (`$(fixed)`), `preferred` must match it."
                    )
                end
            else
                error(
                    "Invalid `timestep_hint.preferred` for process `$(process)` at scale `$(scale)`: ",
                    "expected `:finest`, `:coarsest`, or `Dates.FixedPeriod`, got `$(typeof(preferred))`."
                )
            end
        end
        return _ResolvedTimeStepHint(fixed, range, preferred)
    end

    error(
        "Invalid `timestep_hint` for process `$(process)` at scale `$(scale)`: ",
        "expected `nothing`, `Dates.FixedPeriod`, `(min,max)` tuple, or NamedTuple, got `$(typeof(hint))`."
    )
end

function _infer_timestep_hints!(model_specs)
    # `timestep_hint` is parsed/validated here but does not assign runtime dt.
    # Runtime derives dt from:
    # 1) explicit `ModelSpec.timestep`
    # 2) model `timespec(model)` when non-default
    # 3) meteo base step (default fallback)
    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            isnothing(timestep(spec)) || continue
            _normalize_timestep_hint(scale, process, timestep_hint(model_(spec)))
        end
    end

    return nothing
end

function _format_candidate_list(candidates)
    isempty(candidates) && return "(none)"
    return join(["$(c.scale)/$(c.process)" for c in candidates], ", ")
end

function _is_stream_only_output(spec::ModelSpec, var::Symbol)
    routing = output_routing(spec)
    mode = var in keys(routing) ? routing[var] : :canonical
    return mode == :stream_only
end

function _scale_reachable(scale_reachability, consumer_scale::Symbol, source_scale::Symbol)
    isnothing(scale_reachability) && return true
    # If one of the scales is not present in the initial MTG, reachability is
    # unknown at init time: keep candidate permissively.
    haskey(scale_reachability, consumer_scale) || return true
    haskey(scale_reachability, source_scale) || return true
    allowed = scale_reachability[consumer_scale]
    return source_scale in allowed
end

function _scale_reachability_from_mtg(mtg)
    scale_reachability = Dict{Symbol,Set{Symbol}}()

    MultiScaleTreeGraph.traverse!(mtg) do node
        scale = symbol(node)
        push!(get!(scale_reachability, scale, Set{Symbol}()), scale)

        ancestor = parent(node)
        while !isnothing(ancestor)
            ancestor_scale = symbol(ancestor)
            # Scales are reachable only when they appear on the same MTG lineage
            # (ancestor/descendant relation). Sibling-only scales are excluded.
            push!(get!(scale_reachability, scale, Set{Symbol}()), ancestor_scale)
            push!(get!(scale_reachability, ancestor_scale, Set{Symbol}()), scale)
            ancestor = parent(ancestor)
        end
    end

    return scale_reachability
end

function _effective_timestep_spec(spec::ModelSpec)
    ts = timestep(spec)
    return isnothing(ts) ? timespec(model_(spec)) : ts
end

function _timestep_resolution_source(spec::ModelSpec)
    !isnothing(timestep(spec)) && return :modelspec
    return _same_timestep_signature(
        _timestep_signature(timespec(model_(spec))),
        _timestep_signature(ClockSpec(1.0, 0.0))
    ) ? :meteo_base_step : :model_timespec
end

function _timestep_signature(ts)
    if ts isa ClockSpec
        return (:clock, float(ts.dt), float(ts.phase))
    elseif ts isa Real
        return (:step, float(ts), 0.0)
    elseif ts isa Dates.FixedPeriod
        return (:period, _seconds_from_period(ts), 0.0)
    end
    return nothing
end

function _same_timestep_signature(sig_a, sig_b)
    isnothing(sig_a) && return false
    isnothing(sig_b) && return false

    if sig_a[1] == :period || sig_b[1] == :period
        return sig_a[1] == :period &&
               sig_b[1] == :period &&
               isapprox(sig_a[2], sig_b[2]; atol=1.0e-9, rtol=0.0)
    end

    phase_a = sig_a[1] == :step ? 0.0 : sig_a[3]
    phase_b = sig_b[1] == :step ? 0.0 : sig_b[3]
    return isapprox(sig_a[2], sig_b[2]; atol=1.0e-9, rtol=0.0) &&
           isapprox(phase_a, phase_b; atol=1.0e-9, rtol=0.0)
end

function _hard_dep_same_rate_as_parent(model_specs, parent_scale::Symbol, parent_process::Symbol, child_scale::Symbol, child_process::Symbol)
    parent_scale == child_scale || return false
    parent_specs = get(model_specs, parent_scale, nothing)
    isnothing(parent_specs) && return false
    parent_spec = get(parent_specs, parent_process, nothing)
    child_spec = get(parent_specs, child_process, nothing)
    isnothing(parent_spec) && return false
    isnothing(child_spec) && return false

    parent_sig = _timestep_signature(_effective_timestep_spec(parent_spec))
    child_sig = _timestep_signature(_effective_timestep_spec(child_spec))
    return _same_timestep_signature(parent_sig, child_sig)
end

function _collect_same_rate_hard_dependency_children!(
    ignored_processes_by_scale::Dict{Symbol,Set{Symbol}},
    model_specs,
    parent_scale::Symbol,
    parent_process::Symbol,
    child::HardDependencyNode
)
    if _hard_dep_same_rate_as_parent(model_specs, parent_scale, parent_process, child.scale, child.process)
        push!(get!(ignored_processes_by_scale, child.scale, Set{Symbol}()), child.process)
    end

    for nested in child.children
        _collect_same_rate_hard_dependency_children!(
            ignored_processes_by_scale,
            model_specs,
            child.scale,
            child.process,
            nested
        )
    end

    return nothing
end

function _soft_nodes_for_hard_dependency_analysis(dep_graph::DependencyGraph{Dict{Symbol,Any}})
    nodes = SoftDependencyNode[]
    for (_, roots_at_scale) in pairs(dep_graph.roots)
        haskey(roots_at_scale, :soft_dep_graph) || continue
        append!(nodes, values(roots_at_scale[:soft_dep_graph]))
    end
    return nodes
end

_soft_nodes_for_hard_dependency_analysis(dep_graph::DependencyGraph) = traverse_dependency_graph(dep_graph, false)

function _same_rate_hard_dependency_children(model_specs, dep_graph::DependencyGraph)
    ignored_processes_by_scale = Dict{Symbol,Set{Symbol}}()

    for soft_node in _soft_nodes_for_hard_dependency_analysis(dep_graph)
        for child in soft_node.hard_dependency
            _collect_same_rate_hard_dependency_children!(
                ignored_processes_by_scale,
                model_specs,
                soft_node.scale,
                soft_node.process,
                child
            )
        end
    end

    return ignored_processes_by_scale
end

function _active_processes_for_inference(model_specs, ignored_processes_by_scale::Dict{Symbol,Set{Symbol}})
    active = Dict{Symbol,Set{Symbol}}()
    for (scale, specs_at_scale) in pairs(model_specs)
        procs = Set{Symbol}(keys(specs_at_scale))
        ignored = get(ignored_processes_by_scale, scale, Set{Symbol}())
        for process in ignored
            delete!(procs, process)
        end
        active[scale] = procs
    end
    return active
end

function _input_candidates_for_var(
    model_specs,
    consumer_scale::Symbol,
    consumer_process::Symbol,
    input_var::Symbol;
    scale_reachability=nothing,
    active_processes_by_scale=nothing
)
    same_scale = NamedTuple[]
    cross_scale = NamedTuple[]

    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            if !isnothing(active_processes_by_scale)
                active = get(active_processes_by_scale, scale, Set{Symbol}())
                process in active || continue
            end
            scale == consumer_scale && process == consumer_process && continue
            input_var in keys(outputs_(model_(spec))) || continue
            _is_stream_only_output(spec, input_var) && continue
            if scale != consumer_scale && !_scale_reachable(scale_reachability, consumer_scale, scale)
                continue
            end
            c = (scale=scale, process=process, var=input_var)
            if scale == consumer_scale
                push!(same_scale, c)
            else
                push!(cross_scale, c)
            end
        end
    end

    return same_scale, cross_scale
end

function _default_policy_for_inferred_binding(model_specs, source_scale::Symbol, source_process::Symbol, source_var::Symbol)
    source_spec = model_specs[source_scale][source_process]
    source_model = model_(source_spec)
    source_output_policy = output_policy(source_model)
    source_var in keys(source_output_policy) || return HoldLast()
    return _as_schedule_policy(
        source_output_policy[source_var];
        context="output_policy for inferred binding from `$(source_scale)/$(source_process).$(source_var)`"
    )
end

function _infer_input_binding_for_var(
    model_specs,
    scale::Symbol,
    process::Symbol,
    input_var::Symbol;
    scale_reachability=nothing,
    active_processes_by_scale=nothing
)
    same_scale, cross_scale = _input_candidates_for_var(
        model_specs,
        scale,
        process,
        input_var;
        scale_reachability=scale_reachability,
        active_processes_by_scale=active_processes_by_scale
    )

    if length(same_scale) == 1
        c = only(same_scale)
        policy = _default_policy_for_inferred_binding(model_specs, c.scale, c.process, c.var)
        return (process=c.process, var=c.var, policy=policy)
    elseif length(same_scale) > 1
        error(
            "Ambiguous inferred producer for input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
            "Multiple same-scale candidates were found: $(_format_candidate_list(same_scale)). ",
            "Please provide explicit `InputBindings(...)`."
        )
    end

    if length(cross_scale) == 1
        c = only(cross_scale)
        policy = _default_policy_for_inferred_binding(model_specs, c.scale, c.process, c.var)
        return (process=c.process, var=c.var, scale=c.scale, policy=policy)
    elseif length(cross_scale) > 1
        by_process = Dict{Symbol,Vector{NamedTuple}}()
        for c in cross_scale
            push!(get!(by_process, c.process, NamedTuple[]), c)
        end

        if length(by_process) == 1
            proc = only(keys(by_process))
            scales = unique(c.scale for c in by_process[proc])
            if length(scales) == 1
                src_scale = only(scales)
                policy = _default_policy_for_inferred_binding(model_specs, src_scale, proc, input_var)
                return (process=proc, var=input_var, scale=src_scale, policy=policy)
            end
            # Same process name appears at multiple scales (common in multiscale
            # mappings). Keep scale unresolved so runtime resolves through parent links.
            return (process=proc, var=input_var, policy=HoldLast())
        end

        error(
            "Ambiguous inferred producer for input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
            "Multiple cross-scale candidates were found: $(_format_candidate_list(cross_scale)). ",
            "Please provide explicit `InputBindings(...)`."
        )
    end

    # No producer found. Keep input unresolved so user-provided initialization/forced
    # values can still drive the model.
    return nothing
end

function _infer_input_bindings!(model_specs; scale_reachability=nothing, active_processes_by_scale=nothing)
    for (scale, specs_at_scale) in pairs(model_specs)
        # When a scale is absent from the initial MTG, input producer inference at
        # init time is unreliable (dynamic growth may introduce it later). Keep
        # bindings unresolved and let runtime resolve from actual dependencies.
        if !isnothing(scale_reachability) && !haskey(scale_reachability, scale)
            continue
        end
        for (process, spec) in pairs(specs_at_scale)
            if !isnothing(active_processes_by_scale)
                active = get(active_processes_by_scale, scale, Set{Symbol}())
                process in active || continue
            end
            current_bindings = input_bindings(spec)
            current_bindings isa NamedTuple || continue

            inferred = Pair{Symbol,Any}[]
            model_inputs = keys(inputs_(model_(spec)))

            for input_var in model_inputs
                input_var in keys(current_bindings) && continue
                inferred_binding = _infer_input_binding_for_var(
                    model_specs,
                    scale,
                    process,
                    input_var;
                    scale_reachability=scale_reachability,
                    active_processes_by_scale=active_processes_by_scale
                )
                isnothing(inferred_binding) && continue
                push!(inferred, input_var => inferred_binding)
            end

            isempty(inferred) && continue
            merged = (; pairs(current_bindings)..., inferred...)
            specs_at_scale[process] = ModelSpec(spec; input_bindings=merged)
        end
    end

    return nothing
end

function _normalize_meteo_hint(scale::Symbol, process::Symbol, hint)
    isnothing(hint) && return (bindings=nothing, window=nothing)

    hint isa NamedTuple || error(
        "Invalid `meteo_hint` for process `$(process)` at scale `$(scale)`: ",
        "expected NamedTuple with optional fields `bindings` and `window`, got `$(typeof(hint))`."
    )

    allowed = (:bindings, :window)
    extra = setdiff(collect(keys(hint)), collect(allowed))
    isempty(extra) || error(
        "Invalid `meteo_hint` for process `$(process)` at scale `$(scale)`: ",
        "unsupported fields $(extra)."
    )

    bindings = haskey(hint, :bindings) ? _normalize_meteo_bindings(hint.bindings) : nothing
    window = haskey(hint, :window) ? _normalize_meteo_window(hint.window) : nothing
    return (bindings=bindings, window=window)
end

function _infer_meteo_hints!(model_specs)
    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            hint = _normalize_meteo_hint(scale, process, meteo_hint(model_(spec)))

            current_bindings = meteo_bindings(spec)
            has_explicit_bindings = !(current_bindings isa NamedTuple && isempty(keys(current_bindings)))
            new_bindings = has_explicit_bindings ? current_bindings : (isnothing(hint.bindings) ? current_bindings : hint.bindings)

            current_window = meteo_window(spec)
            new_window = isnothing(current_window) ? (isnothing(hint.window) ? current_window : hint.window) : current_window

            if (new_bindings !== current_bindings) || (new_window !== current_window)
                specs_at_scale[process] = ModelSpec(spec; meteo_bindings=new_bindings, meteo_window=new_window)
            end
        end
    end

    return nothing
end

"""
    infer_model_specs_configuration!(model_specs)

Fill missing `ModelSpec` fields from inference:
- auto input bindings from unique same-name producers
  (including default policy from producer `output_policy`)
- model-level hint traits (`timestep_hint`, `meteo_hint`)
Explicit `ModelSpec` user values always take precedence over inferred values.
"""
function infer_model_specs_configuration!(model_specs; scale_reachability=nothing, active_processes_by_scale=nothing)
    _infer_input_bindings!(
        model_specs;
        scale_reachability=scale_reachability,
        active_processes_by_scale=active_processes_by_scale
    )
    _infer_timestep_hints!(model_specs)
    _infer_meteo_hints!(model_specs)
    return model_specs
end

"""
    resolved_model_specs(mapping; infer=true, validate=true)
    resolved_model_specs(sim::GraphSimulation)

Return process-indexed `ModelSpec` dictionaries as used by runtime:
`Dict{Symbol, Dict{Symbol, ModelSpec}}`.

For a mapping, this parses model declarations and optionally applies inference
(`timestep_hint`, `meteo_hint`) and validation.
For a `GraphSimulation`, this returns the already resolved model specs used by the simulation.
"""
function resolved_model_specs(mapping::AbstractDict; infer::Bool=true, validate::Bool=true)
    model_specs = Dict{Symbol,Dict{Symbol,ModelSpec}}()
    for (scale, declarations) in pairs(mapping)
        scale_sym = if scale isa Symbol
            scale
        elseif scale isa AbstractString
            _normalize_scale(scale; warn=true, context=:ModelSpec)
        else
            error("Scale keys in `resolved_model_specs(mapping)` must be `Symbol` (preferred) or `String`, got `$(typeof(scale))`.")
        end
        model_specs[scale_sym] = parse_model_specs(declarations)
    end

    infer && infer_model_specs_configuration!(model_specs)
    validate && validate_model_specs_configuration(model_specs)
    return model_specs
end

resolved_model_specs(sim::GraphSimulation; infer::Bool=true, validate::Bool=true) = get_model_specs(sim)

function _stringify_compact(x; maxlen::Int=120)
    s = sprint(show, x)
    return ncodeunits(s) <= maxlen ? s : string(first(s, maxlen - 3), "...")
end

function _model_specs_rows(model_specs)
    rows = NamedTuple[]
    for scale in sort!(collect(keys(model_specs)))
        specs_at_scale = model_specs[scale]
        for process in sort!(collect(keys(specs_at_scale)); by=string)
            spec = specs_at_scale[process]
            resolution = _timestep_resolution_source(spec)
            push!(rows, (
                scale=scale,
                process=process,
                model=typeof(model_(spec)),
                timestep=timestep(spec),
                timespec_default=timespec(model_(spec)),
                timestep_resolution=resolution,
                input_bindings=input_bindings(spec),
                meteo_bindings=meteo_bindings(spec),
                meteo_window=meteo_window(spec),
            ))
        end
    end
    return rows
end

"""
    explain_model_specs(target; io=stdout, infer=true, validate=true)

Print a compact per-model summary of resolved runtime configuration and return it
as a vector of named tuples.

Summary fields:
- `scale`
- `process`
- `model`
- `timestep`
- `input_bindings`
- `meteo_bindings`
- `meteo_window`
"""
function explain_model_specs(target; io::IO=stdout, infer::Bool=true, validate::Bool=true)
    specs = target isa GraphSimulation ? resolved_model_specs(target) : resolved_model_specs(target; infer=infer, validate=validate)
    rows = _model_specs_rows(specs)

    println(io, "Resolved model specs:")
    if isempty(rows)
        println(io, "  (no model specs)")
        return rows
    end

    for row in rows
        timestep_desc = if row.timestep_resolution == :modelspec
            string(_stringify_compact(row.timestep), " [explicit ModelSpec]")
        elseif row.timestep_resolution == :model_timespec
            string(_stringify_compact(row.timespec_default), " [model timespec]")
        else
            "(meteo base step at runtime)"
        end
        input_bindings_desc = (row.input_bindings isa NamedTuple && isempty(keys(row.input_bindings))) ? "(none)" : _stringify_compact(row.input_bindings)
        meteo_bindings_desc = (row.meteo_bindings isa NamedTuple && isempty(keys(row.meteo_bindings))) ? "(none)" : _stringify_compact(row.meteo_bindings)
        meteo_window_desc = isnothing(row.meteo_window) ? "(default rolling)" : _stringify_compact(row.meteo_window)
        println(
            io,
            "  - ",
            row.scale,
            "/",
            row.process,
            " [",
            row.model,
            "]: timestep=",
            timestep_desc,
            ", input_bindings=",
            input_bindings_desc,
            ", meteo_bindings=",
            meteo_bindings_desc,
            ", meteo_window=",
            meteo_window_desc
        )
    end
    return rows
end
