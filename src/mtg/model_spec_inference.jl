const _TIMESTEP_HINT_FIELDS = (:required, :preferred)

"""
    timestep_hint(model::AbstractModel)
    timestep_hint(::Type{<:AbstractModel})

Optional model trait used to infer a timestep when `ModelSpec.timestep` is not provided.

Supported return values:
- `nothing` (default): no hint
- `Dates.FixedPeriod`: fixed required timestep
- `(min_period, max_period)`: required timestep range (`Dates.FixedPeriod` pair)
- `NamedTuple`: with `required` (one of the forms above) and optional `preferred`
  (`:finest`, `:coarsest`, or a `Dates.FixedPeriod` within the required range)
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

function _period_from_seconds(seconds::Float64)
    ms = round(Int, seconds * 1000.0)
    return Dates.Millisecond(ms)
end

function _normalize_required_timestep_hint(scale::String, process::Symbol, required)
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

function _normalize_timestep_hint(scale::String, process::Symbol, hint)
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

function _resolve_range_consensus(
    range_specs::Vector{Tuple{String,Symbol,ModelSpec,_ResolvedTimeStepHint}}
)
    isempty(range_specs) && return nothing

    lo = maximum(_seconds_from_period(s[4].range[1]) for s in range_specs)
    hi = minimum(_seconds_from_period(s[4].range[2]) for s in range_specs)
    lo <= hi || error(
        "No feasible inferred timestep consensus for models without explicit `TimeStepModel(...)`. ",
        "Collected required ranges are incompatible:\n",
        join(
            [
                "  - $(scale)/$(process): ($(hint.range[1]), $(hint.range[2]))" for (scale, process, _, hint) in range_specs
            ],
            "\n"
        )
    )

    preferred_periods = Float64[]
    finest_votes = 0
    coarsest_votes = 0
    for (_, _, _, hint) in range_specs
        pref = hint.preferred
        if pref isa Dates.FixedPeriod
            sec = _seconds_from_period(pref)
            lo <= sec <= hi && push!(preferred_periods, sec)
        elseif pref == :coarsest
            coarsest_votes += 1
        elseif pref == :finest
            finest_votes += 1
        end
    end

    chosen_sec = if !isempty(preferred_periods) && all(isapprox(v, first(preferred_periods); atol=1.0e-6, rtol=0.0) for v in preferred_periods)
        first(preferred_periods)
    elseif coarsest_votes > finest_votes
        hi
    else
        lo
    end

    return _period_from_seconds(chosen_sec)
end

function _infer_timestep_hints!(model_specs)
    range_specs = Tuple{String,Symbol,ModelSpec,_ResolvedTimeStepHint}[]

    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            !isnothing(timestep(spec)) && continue

            hint = _normalize_timestep_hint(scale, process, timestep_hint(model_(spec)))
            if !isnothing(hint.fixed)
                specs_at_scale[process] = ModelSpec(spec; timestep=hint.fixed)
            elseif !isnothing(hint.range)
                push!(range_specs, (scale, process, spec, hint))
            end
        end
    end

    consensus = _resolve_range_consensus(range_specs)
    isnothing(consensus) && return nothing

    for (scale, process, spec, _) in range_specs
        model_specs[scale][process] = ModelSpec(spec; timestep=consensus)
    end

    return nothing
end

function _format_candidate_list(candidates)
    isempty(candidates) && return "(none)"
    return join(["$(c.scale)/$(c.process)" for c in candidates], ", ")
end

function _input_candidates_for_var(model_specs, consumer_scale::String, consumer_process::Symbol, input_var::Symbol)
    same_scale = NamedTuple[]
    cross_scale = NamedTuple[]

    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            scale == consumer_scale && process == consumer_process && continue
            input_var in keys(outputs_(model_(spec))) || continue
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

function _infer_input_binding_for_var(model_specs, scale::String, process::Symbol, input_var::Symbol)
    same_scale, cross_scale = _input_candidates_for_var(model_specs, scale, process, input_var)

    if length(same_scale) == 1
        c = only(same_scale)
        return (process=c.process, var=c.var, policy=HoldLast())
    elseif length(same_scale) > 1
        error(
            "Ambiguous inferred producer for input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
            "Multiple same-scale candidates were found: $(_format_candidate_list(same_scale)). ",
            "Please provide explicit `InputBindings(...)`."
        )
    end

    if length(cross_scale) == 1
        c = only(cross_scale)
        return (process=c.process, var=c.var, scale=c.scale, policy=HoldLast())
    elseif length(cross_scale) > 1
        by_process = Dict{Symbol,Vector{NamedTuple}}()
        for c in cross_scale
            push!(get!(by_process, c.process, NamedTuple[]), c)
        end

        if length(by_process) == 1
            proc = only(keys(by_process))
            scales = unique(c.scale for c in by_process[proc])
            if length(scales) == 1
                return (process=proc, var=input_var, scale=only(scales), policy=HoldLast())
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

function _infer_input_bindings!(model_specs)
    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            current_bindings = input_bindings(spec)
            current_bindings isa NamedTuple || continue

            inferred = Pair{Symbol,Any}[]
            model_inputs = keys(inputs_(model_(spec)))

            for input_var in model_inputs
                input_var in keys(current_bindings) && continue
                inferred_binding = _infer_input_binding_for_var(model_specs, scale, process, input_var)
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

function _normalize_meteo_hint(scale::String, process::Symbol, hint)
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
- model-level hint traits (`timestep_hint`, `meteo_hint`)
Explicit `ModelSpec` user values always take precedence over inferred values.
"""
function infer_model_specs_configuration!(model_specs)
    _infer_input_bindings!(model_specs)
    _infer_timestep_hints!(model_specs)
    _infer_meteo_hints!(model_specs)
    return model_specs
end

"""
    resolved_model_specs(mapping; infer=true, validate=true)
    resolved_model_specs(sim::GraphSimulation)

Return process-indexed `ModelSpec` dictionaries as used by runtime:
`Dict{String, Dict{Symbol, ModelSpec}}`.

For a mapping, this parses model declarations and optionally applies inference
(`timestep_hint`, `meteo_hint`) and validation.
For a `GraphSimulation`, this returns the already resolved model specs used by the simulation.
"""
function resolved_model_specs(mapping::AbstractDict; infer::Bool=true, validate::Bool=true)
    model_specs = Dict{String,Dict{Symbol,ModelSpec}}()
    for (scale, declarations) in pairs(mapping)
        model_specs[string(scale)] = parse_model_specs(declarations)
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
            push!(rows, (
                scale=scale,
                process=process,
                model=typeof(model_(spec)),
                timestep=timestep(spec),
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
        timestep_desc = isnothing(row.timestep) ? "(timespec(model))" : _stringify_compact(row.timestep)
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
