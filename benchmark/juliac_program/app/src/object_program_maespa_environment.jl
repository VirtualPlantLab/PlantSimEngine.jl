# Included inside RegistryPrograms. This is an explicit binding adapter for the
# unchanged MAESPA EnvironmentAPI, not an alternative canopy/soil calculation.
import MAESPA

struct MAESPAEnvironmentBinding{B,H,P,A,R,PROVIDER,SINK}
    backend::B
    handle::H
    schema::P
    atmosphere_type::Type{A}
    row_type::Type{R}
end

"""Project the original forcing backend onto its existing concrete row storage.

Both representations share every row. Runtime row updates remain visible; the
admitted fixed forcing does not replace the table's storage or column schema.
The original GlobalConstant sampler and timestep validators remain in use.
"""
function _prepare_maespa_backend(backend)
    backend isa MAESPA.MAESPACanopyEnvironment || throw(ArgumentError("expected the original MAESPA canopy backend"))
    original=backend.forcing_backend
    original isa PSE.GlobalConstant || throw(ArgumentError("fixed MAESPA forcing requires the original GlobalConstant backend"))
    original.source===backend.forcing || throw(ArgumentError("forcing backend and table must share their source"))
    hasfield(typeof(backend.forcing),:ts) || throw(ArgumentError("forcing table has no admitted raw row storage"))
    rows=getfield(backend.forcing,:ts)
    rows isa Vector{<:NamedTuple} || throw(ArgumentError("forcing requires concrete NamedTuple row storage"))
    !isempty(rows) || throw(ArgumentError("forcing row storage must not be empty"))
    Tuple(propertynames(backend.forcing))==keys(first(rows)) || throw(ArgumentError("forcing columns differ from their raw row schema"))
    forcing_backend=PSE.GlobalConstant(rows)
    isequal(PSE.EnvironmentAPI.base_step_seconds(forcing_backend),PSE.EnvironmentAPI.base_step_seconds(original)) ||
        throw(ArgumentError("raw forcing rows changed the admitted base step"))
    prepared=MAESPA.MAESPACanopyEnvironment{typeof(backend.forcing),typeof(forcing_backend)}(
        backend.forcing,forcing_backend,backend.canopy)
    if !isnothing(prepared.canopy)
        MAESPA._validate_canopy_atmosphere(prepared.canopy)
        MAESPA._validate_canopy_atmosphere_timestep(prepared.forcing_backend,prepared.canopy)
    end
    return prepared
end

@inline function _prepared_maespa_handle(binding::MAESPAEnvironmentBinding{B,H,P,A,R,PROVIDER,SINK}) where {B,H,P,A,R,PROVIDER,SINK}
    # Original immutable handle, with the already admitted provider/sink made
    # literal at this compiled boundary. Its forcing handle is unchanged.
    return H(PROVIDER,SINK,binding.handle.forcing_handle)
end

function _maespa_atmosphere_type(model,resolved_targets)
    types=DataType[]
    for (application,targets) in resolved_targets
        haskey(PSE.environment_outputs_(application.spec),:air_temperature_c) || continue
        for target in targets
            T=if target.model isa MAESPA.MAESPACanopyAirIterationController
                MAESPA._canopy_air_iteration_output_type(target.status)
            elseif target.model isa MAESPA.MAESPAPrescribedCanopyAtmosphere
                typeof(target.status.air_temperature_c)
            else
                throw(ArgumentError("unadmitted MAESPA environment committer schema"))
            end
            push!(types,T)
        end
    end
    unique!(types)
    length(types)==1 || throw(ArgumentError("fixed registry backend requires one effective committed canopy scalar schema"))
    T=only(types)
    T<:AbstractFloat && isconcretetype(T) || throw(ArgumentError("committed canopy scalar schema must be concrete"))
    raw=NamedTuple(PSE._environment_row_at_step(model.environment.forcing,1))
    return MAESPA.MAESPACanopyAtmosphere{T,typeof(raw.duration)}
end

function _maespa_row_type(schema,backend,handle,::Type{A}) where {A}
    raw=NamedTuple(PSE._environment_row_at_step(backend.forcing,1))
    raw_type=typeof(raw)
    scalar_type=fieldtype(A,:air_temperature_c)
    types=map(values(schema)) do source
        if source===:canopy_thermal_snapshot
            return MAESPA.MAESPACanopyThermalSnapshot{scalar_type}
        elseif source in (:canopy_air_iteration_index,:canopy_air_maximum_iterations)
            return Int
        elseif source in (:canopy_air_iteration_enabled,:canopy_air_first_evaluation,:canopy_air_last_allowed_evaluation)
            return Bool
        elseif handle.provider===:forcing
            hasfield(raw_type,source) || throw(ArgumentError("forcing source does not provide $source"))
            return fieldtype(raw_type,source)
        else
            hasfield(A,source) || throw(ArgumentError("canopy source does not provide $source"))
            return fieldtype(A,source)
        end
    end
    return NamedTuple{keys(schema),Tuple{types...}}
end

function _prepare_maespa_environment(backend,handle,schema,::Type{A}) where {A}
    backend isa MAESPA.MAESPACanopyEnvironment || throw(ArgumentError("expected the original MAESPA canopy backend"))
    isconcretetype(A) && A<:MAESPA.MAESPACanopyAtmosphere || throw(ArgumentError("canopy atmosphere schema must be concrete"))
    backend.canopy isa Union{Nothing,A} || throw(ArgumentError("initial committed canopy has a different admitted schema"))
    R=_maespa_row_type(schema,backend,handle,A)
    return MAESPAEnvironmentBinding{typeof(backend),typeof(handle),typeof(schema),A,R,handle.provider,handle.sink}(
        backend,handle,schema,A,R)
end

"""Authoring projection of an already resolved ordinary environment binding.
No ordinary binding/plan/context is retained by the returned native binding.
"""
function prepare_environment(binding::PSE.CompiledEnvironmentBinding;atmosphere_type,backend)
    schema=PSE._prepared_environment_inputs(binding.compiled_sampling_rules)
    return _prepare_maespa_environment(backend,binding.handle,schema,atmosphere_type)
end

@generated function _sample_maespa_forcing(binding,time,
        ::PSE.EnvironmentAPI.PreparedEnvironmentInputs{TARGETS,SOURCES,RAW}) where {TARGETS,SOURCES,RAW}
    calls=[:(PSE.EnvironmentAPI.sample(binding.backend.forcing_backend,binding.handle.forcing_handle,
        $(QuoteNode(source)),time)) for source in SOURCES]
    return Expr(:call,NamedTuple{TARGETS},Expr(:tuple,calls...))
end

function _sample_maespa(binding::MAESPAEnvironmentBinding{B,H,P,A,R},::Nothing,time) where {B,H,P,A,R}
    handle=_prepared_maespa_handle(binding)
    if handle.provider===:forcing
        return _sample_maespa_forcing(binding,time,binding.schema)::R
    end
    isempty(keys(binding.schema)) && return NamedTuple()::R
    committed=binding.backend.canopy::Union{Nothing,A}
    isnothing(committed) && MAESPA._missing_committed_canopy_atmosphere(first(values(binding.schema)))
    return PSE.EnvironmentAPI.sample_environment(binding.backend,handle,committed::A,time,binding.schema)::R
end
function _sample_maespa(binding::MAESPAEnvironmentBinding{B,H,P,A,R},override::Union{
        MAESPA.MAESPACanopyAtmosphere,MAESPA.MAESPACanopyAirTrialEnvironment},time) where {B,H,P,A,R}
    return PSE.EnvironmentAPI.sample_environment(binding.backend,_prepared_maespa_handle(binding),override,time,binding.schema)::R
end
sample(binding::MAESPAEnvironmentBinding,time;override=nothing)=_sample_maespa(binding,override,time)

_committed_canopy(binding::MAESPAEnvironmentBinding{B,H,P,A,R}) where {B,H,P,A,R}=
    binding.backend.canopy::Union{Nothing,A}

"""Original sink validation/commit; the native call tree controls suppression."""
function commit(binding::MAESPAEnvironmentBinding{B,H,P,A,R},accepted,time) where {B,H,P,A,R}
    state=accepted::A
    PSE.EnvironmentAPI.commit_environment!(binding.backend,_prepared_maespa_handle(binding),state,time)
    return nothing
end
