module LocalPortsSelectedBridge

using PlantSimEngine, XPalm, SHA
const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const Native = Main.NativePBDriver
const Shared = Main.SharedCallProgram
const Tight = Main.TightCallProgram

export register_local_ports_models!, register_xpalm_local_ports!,
    local_ports_registration_report

# A metadata-only probe identifies the three generic fallback methods. It is
# never a scientific model and has no run! method or mutable scientific state.
struct DefaultCapabilityProbe end
const _registered = Dict{Any,NamedTuple}()
const _attempts = NamedTuple[]

_default_method(function_) = which(function_, Tuple{Type{DefaultCapabilityProbe}})
_selected_method(function_, type) = which(function_, Tuple{Type{type}})

function _proof(model)
    type = typeof(model)
    isabstracttype(type) && return (accepted=false, reason=:abstract_model,)
    model isa PSE.AbstractModel || return (accepted=false, reason=:not_model,)
    CR.region_effects(type) === :local_ports || return (accepted=false, reason=:no_existing_local_ports_audit,)
    isempty(PSE.dep(model)) || return (accepted=false, reason=:model_dependencies_not_empty,)
    isempty(PSE.environment_outputs_(model)) || return (accepted=false, reason=:environment_commit_boundary,)
    isempty(PSE._distributed_output_schema(model)) || return (accepted=false, reason=:distributed_output_boundary,)
    method = try
        which(PSE.run!, Tuple{type,Any,Any,Any,Any})
    catch
        return (accepted=false, reason=:no_generic_context_method,)
    end
    signature = Base.unwrap_unionall(method.sig)
    signature isa DataType && length(signature.parameters) == 6 ||
        return (accepted=false, reason=:nonfixed_run_signature,)
    signature.parameters[6] === Any ||
        return (accepted=false, reason=:private_context_dispatch_not_proven,)
    path = String(method.file)
    return (accepted=true, reason=:audited_call_free_context_independent_kernel,
        source_method=string(method), source_file=path, source_line=Int(method.line),
        source_sha256=isfile(path) ? bytes2hex(sha256(read(path))) : nothing,
        untyped_context=true, declared_dependencies=0,
        source_capability=:local_ports, scientific_methods_changed=false)
end

"""
    register_local_ports_models!(models)

Optional exact-type admission from an EXISTING :local_ports audit. That audit
already excludes context observation/escape, representation-dependent dispatch,
RNG, mutable shared caches and nonlocal status aliases. Empty declared
dependencies and a genuinely untyped five-argument run! context are additionally
required here. No scientific method is wrapped, evaluated or rewritten.

Only previously generic Native/Shared/Tight fallback capabilities are extended.
An explicit capability method, even one returning a fallback value, is never
overwritten. This changes admission globally for the exact registered types:
load/register uniformly BEFORE ALL arms in a separate comparison worker. Do
not mix its observations with the original frozen zero-eligibility cohort.
"""
Base.@nospecializeinfer @noinline function register_local_ports_models!(models)
    @nospecialize models
    rows = NamedTuple[]
    for model in models
        type = typeof(model)
        if haskey(_registered, type)
            row = merge(_registered[type], (status=:already_registered,))
            push!(rows, row); push!(_attempts, row)
            continue
        end
        proof = _proof(model)
        if !proof.accepted
            row = (; model_type=string(type), status=:rejected, proof...)
            push!(rows, row); push!(_attempts, row)
            continue
        end
        explicit = Symbol[]
        for (name, function_) in ((:native, Native.native_call_effects),
            (:shared, Shared.shared_context_effects), (:tight, Tight.tight_call_effects))
            _selected_method(function_, type) === _default_method(function_) || push!(explicit, name)
        end
        if !isempty(explicit)
            row = (; model_type=string(type), status=:rejected, accepted=false,
                reason=:explicit_capability_preserved, explicit=Tuple(explicit))
            push!(rows, row); push!(_attempts, row)
            continue
        end
        Core.eval(Native, :(native_call_effects(::Type{$type}) = :fixed_native_calls))
        Core.eval(Shared, :(shared_context_effects(::Type{$type}) = :synchronous_borrowed_context))
        Core.eval(Tight, :(tight_call_effects(::Type{$type}) = $(QuoteNode(Tight._TIGHT_CAPABILITY))))
        row = (; model_type=string(type), status=:registered, proof...)
        _registered[type] = row
        push!(rows, row); push!(_attempts, row)
    end
    return (; rows, registered_types=length(_registered),
        exact_type_methods_only=true, generic_defaults_overwritten=false,
        scientific_kernel_execution=false, scientific_methods_changed=false,
        qualification=:optional_changed_admission_uniformly_before_all_comparison_arms)
end

"""Four original pure scheduled XP kernels; no model/package dispatch in planners."""
register_xpalm_local_ports!() = register_local_ports_models!((
    XPalm.DailyPlantAgeModel(), XPalm.DailyDegreeDays(),
    XPalm.DailyDegreeDaysSinceInit(), XPalm.PhyllochronModel()))

function local_ports_registration_report()
    rows = sort!(collect(values(_registered)); by=row -> row.model_type)
    return (; registered_types=length(rows), registrations=rows, attempts=copy(_attempts),
        retained_scientific_instances=false, exact_type_methods_only=true,
        generic_defaults_overwritten=false, scientific_methods_changed=false,
        qualifier=:separate_optional_admission_cohort)
end

end # module
