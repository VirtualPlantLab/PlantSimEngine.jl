module LeanNativeDriver

using PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP

export LeanNumericalBatch, LeanDriverCounters, make_lean_batch,
    lean_batch_report, bounded_driver_checks

"""Executed work, kept separately from selection/allocation diagnostics."""
mutable struct LeanDriverCounters
    driver_batches::Int
    driver_rows::Int
    native_rows::Int
    native_fields::Int
    publication_rows::Int
end
LeanDriverCounters() = LeanDriverCounters(0, 0, 0, 0, 0)

"""
One numerical batch. Its type contains a model/port schema and a bounded real
RunContext interface. The provider schema and constants stay concrete at the
sampling boundary. The application and scene descriptors are erased; no
compiled-scene or application-stack tuple enters this batch type.

`targets` is an erased lazy target facade for diagnostics and the ordinary
scheduler's work counters. There are no eagerly built rich execution targets,
per-object contexts or per-object call caches.
Models admitted here explicitly promise `region_effects(Type) == :local_ports`.
Unsupported models and bindings remain ordinary execution batches.
"""
mutable struct LeanNumericalBatch{K,D,EP} <: PSE.AbstractExecutionBatch
    application::Any
    targets::AbstractVector
    kernel::K
    data::D
    environment_provider::EP
    output_publication::Any
    counters::LeanDriverCounters
    native::Bool
end

_cell_type(::Ref{T}) where {T} = T

function _concrete_vector(values)
    isempty(values) && return Any[]
    T = typeof(first(values))
    all(value -> typeof(value) === T, values) ||
        throw(ArgumentError("lean numerical batches require homogeneous field types"))
    return T[value for value in values]
end

function _native_column(references)
    isempty(references) && throw(ArgumentError("lean columns cannot be empty"))
    first_ref = first(references)
    first_ref isa Base.RefArray ||
        throw(ArgumentError("declared port does not use native canonical storage"))
    source = getfield(first_ref, :x)
    source isa Vector && isconcretetype(eltype(source)) && isbitstype(eltype(source)) ||
        throw(ArgumentError("declared native port must be a concrete scalar vector"))
    all(reference -> reference isa Base.RefArray && getfield(reference, :x) === source,
        references) || throw(ArgumentError("declared port has heterogeneous native owners"))
    indices = Int[getfield(reference, :i) for reference in references]
    # Exact indexed borrowing handles holes, arbitrary order and repeated
    # physical aliases. It does not copy scientific values or reorder rows.
    return indices == collect(1:length(indices)) ? source : view(source, indices)
end

function _port_names(models, statuses)
    model = first(models)
    CR.region_effects(typeof(model)) === :local_ports ||
        throw(ArgumentError("lean numerical kernels require an explicit local_ports capability"))
    names = Tuple(unique((keys(PSE.inputs_(model))..., keys(PSE.outputs_(model))...)))
    writes = Tuple(keys(PSE.outputs_(model)))
    for (model, status) in zip(models, statuses)
        CR.region_effects(typeof(model)) === :local_ports ||
            throw(ArgumentError("model has no local_ports capability"))
        Tuple(unique((keys(PSE.inputs_(model))..., keys(PSE.outputs_(model))...))) == names &&
            Tuple(keys(PSE.outputs_(model))) == writes ||
            throw(ArgumentError("lean batch has heterogeneous declared ports"))
        all(name -> hasproperty(status, name), names) ||
            throw(ArgumentError("lean batch is missing a declared status port"))
    end
    return names
end

function _data(statuses, names, strategy)
    references = map(names) do name
        refs = [PSE.refvalue(status, name) for status in statuses]
        all(reference -> isconcretetype(_cell_type(reference)) && isbitstype(_cell_type(reference)), refs) ||
            throw(ArgumentError("lean declared ports require concrete isbits values"))
        refs
    end
    if strategy === :native
        arrays = NamedTuple{names}(map(_native_column, references))
        recipe = GP.LocalStateRecipe{names,ntuple(identity, length(names))}()
        return GP.ColumnData(arrays, recipe, length(statuses))
    end
    columns = NamedTuple{names}(map(_concrete_vector, references))
    return CR.RegionReferenceData(columns, length(statuses))
end

"""
    make_lean_batch(application, ids, models, statuses, provider, output_bindings,
        compiled, environment_bindings, streams, retention, constants;
        state_strategy=:native)

Lower already validated logical bindings directly to typed numerical payloads.
No ordinary execution-target constructor is called. `statuses` must be the
canonical runtime views made by the semantic compiler, with live input aliases.
The caller proves no temporal materialization, calls, distributed destinations,
or per-object environment boundaries are required; this constructor also checks
the explicit model capability, scalar schemas and physical storage.

An actual RunContext preserves kernel dispatch. Its scene fields have type Any;
the audited capability forbids observing context fields, identities, references,
status representation or non-port state. Unknown kernels use ordinary contexts.
"""
Base.@nospecializeinfer @noinline function make_lean_batch(
    application, ids, models, statuses, provider, output_bindings,
    compiled, environment_bindings, streams, retention, constants;
    state_strategy::Symbol=:native, target_view=ids, validated_names=nothing,
)
    @nospecialize application ids models statuses provider output_bindings compiled environment_bindings streams retention constants
    state_strategy in (:native, :references) ||
        throw(ArgumentError("state_strategy must be :native or :references"))
    nrows = length(ids)
    nrows > 0 || throw(ArgumentError("lean numerical batches cannot be empty"))
    length(models) == nrows && length(statuses) == nrows && length(output_bindings) == nrows ||
        throw(ArgumentError("lean numerical payloads must have aligned rows"))
    provider isa PSE.UnspecifiedModelEnvironment &&
        throw(ArgumentError("per-object environment sampling is an ordinary execution boundary"))
    # The direct compiler has already checked every logical row. Standalone
    # callers still take the full proof path; no model-schema work is repeated
    # per organ when the semantic compiler supplied the validated port names.
    names = isnothing(validated_names) ? _port_names(models, statuses) : validated_names
    data = _data(statuses, names, state_strategy)
    first_model = first(models)
    model_payload = all(model -> model === first_model, models) ?
        GP.SharedColumnModel(first_model) : GP.PerRowColumnModels(_concrete_vector(models))
    all(row -> all(output -> output isa PSE.RuntimeOutputStream, row), output_bindings) ||
        throw(ArgumentError("distributed publication requires the ordinary executor"))
    publication = PSE._compiled_output_publication(retention, application)
    bindings = publication.enabled ? _concrete_vector(output_bindings) : nothing
    # Construct this bounded context directly. Constructing a fully typed
    # context and then erasing it would still pay scene-dependent cold work.
    environment = PSE._NO_ENVIRONMENT_OVERRIDE
    context = PSE.RunContext{Any,Any,Any,Any,Any,Any,Any,typeof(constants),typeof(environment)}(
        compiled, environment_bindings, application, first(ids), (), NamedTuple(),
        NamedTuple(), streams, retention, 0.0, constants, true, environment)
    # Sampling belongs to the control plane. Only the sampled value's type
    # reaches the noinline numerical function boundary on each invocation.
    kernel = GP.ColumnKernel{publication.enabled,typeof(model_payload),typeof(context),
        Nothing,typeof(bindings)}(model_payload, context, nothing, bindings)
    return LeanNumericalBatch(application, target_view, kernel,
        data, provider, publication, LeanDriverCounters(), state_strategy === :native)
end

# Specialize only on one model/port/environment/constants signature. Neither a
# Simulation nor a CompiledCompositeModel enters the numerical function type.
@noinline function _numerical_rows!(batch::LeanNumericalBatch{K,D}, environment::E,
    constants::C, step) where {K,D,E,C}
    GP._column_numerical_loop!(batch.data, (batch.kernel,), (environment,), constants, step)
    return nothing
end

Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::LeanNumericalBatch{K,D,EP}, compiled::PSE.CompiledCompositeModel,
    environment_bindings::PSE.CompiledEnvironmentBindings, time::Real,
    constants::C, temporal_streams, output_retention,
) where {K,D,EP,C}
    @nospecialize compiled environment_bindings temporal_streams output_retention
    environment = PSE._model_execution_batch_environment(batch.environment_provider,
        environment_bindings, batch.application, time)
    batch.kernel.context.time = float(time)
    # Pass the stable batch identity across the sampled-environment boundary;
    # boxing two immutable numerical headers here costs every application step.
    _numerical_rows!(batch, environment, constants, time)
    counters = batch.counters
    counters.driver_batches += 1
    counters.driver_rows += batch.data.nrows
    if batch.native
        counters.native_rows += batch.data.nrows
        counters.native_fields += length(keys(batch.data.arrays)) * batch.data.nrows
    end
    batch.kernel isa GP.ColumnKernel{true} && (counters.publication_rows += batch.data.nrows)
    return nothing
end

function lean_batch_report(batch::LeanNumericalBatch)
    counters = batch.counters
    names = batch.native ? keys(batch.data.arrays) : keys(batch.data.references)
    return (application=batch.application.id, rows=length(batch.targets),
        native=batch.native, port_names=names, batch_type=string(typeof(batch)),
        driver_batches=counters.driver_batches, driver_rows=counters.driver_rows,
        native_rows=counters.native_rows, native_fields=counters.native_fields,
        publication_rows=counters.publication_rows,
        rich_targets=0, contexts=1, numerical_scalar_copies=false,
        sampling=:ordinary_batch_boundary, outer_stack=:ordinary_dynamic_scheduler,
        specialization=:single_model_ports_environment_constants_signature)
end

"""Source-independent live-column gate; root runs it through Kaimon."""
function bounded_driver_checks()
    values_ = Float32[1, 2, 3]
    selected = _native_column([Ref(values_, row) for row in (3, 1, 3)])
    @assert collect(selected) == Float32[3, 1, 3]
    selected[1] = 9.0f0
    @assert values_[3] === 9.0f0 && selected[3] === 9.0f0
    push!(values_, 4.0f0)
    @assert collect(selected) == Float32[9, 1, 9]
    @assert fieldtype(LeanNumericalBatch, :application) === Any
    @assert fieldtype(LeanNumericalBatch{Nothing,Nothing,Nothing}, :environment_provider) === Nothing
    @assert fieldtype(LeanNumericalBatch, :targets) === AbstractVector
    return (passed=true, arbitrary_order=true, repeated_aliases=true,
        appended_storage=true, scalar_copies=false, scene_typed_fields=false)
end

end # module
