module NativePBDriver

using Dates
using Test
using PlantSimEngine
using PlantMeteo
using PlantBiophysics

const PSE = PlantSimEngine
const PB = PlantBiophysics
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP

"""
    native_call_effects(::Type) = :ordered

`:fixed_native_calls` is a source capability, not an inferred purity claim.
During one synchronous invocation the model and everything it calls preserve
topology, applications, bindings, model parameters and call membership; they
do not advance the simulation, escape a context, or inspect its type/layout.
Calls form an acyclic graph of singular manual targets. Kernels may throw and
mutate/escape native scientific references. Status reflection and dispatch
must not depend on the physical row-header representation. Declared full
status schemas and canonical RefArray cells remain available to the kernel.

Other kernels retain the normal executor. In particular this promise is
separate from CR.region_effects: an iterative controller is eligible here.
"""
native_call_effects(::Type) = :ordered

const PB_NATIVE_CALL_AUDIT = (
    (model=PB.Monteith(), source="processes/energy/Monteith.jl",
        evidence="Original iterative controller; only synchronous sampled photosynthesis calls; full live state; no topology/context escape"),
    (model=PB.Fvcb(), source="processes/photosynthesis/FvCB.jl",
        evidence="Original typed stomatal call_model, gs_coupling, and sampled conductance call; no structural or parameter mutation"),
    (model=PB.Medlyn(0.03, 12.0), source="processes/conductances/stomatal/stomatal_conductance.jl",
        evidence="Original generic conductance law and Medlyn closure use live scalar state; no context observation"),
)
for row in PB_NATIVE_CALL_AUDIT
    T = typeof(row.model)
    @eval native_call_effects(::Type{$T}) = :fixed_native_calls
end

mutable struct NativeCallCounters
    roots::Int
    numerical_calls::Int
    model_lookups::Int
    fallback_calls::Int
    ordinary_batches::Int
    numerical_fields::Int
    native_fields::Int
    root_guard_failures::Int
    direct_roots::Int
    direct_calls::Int
    direct_fields::Int
end
NativeCallCounters() = NativeCallCounters(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

mutable struct NativeCallLease
    running::Bool
    task_id::UInt
    compiled::Any
    environment_bindings::Any
    model_revision::Int
    runtime_revision::Int
    environment_revision::Int
end
NativeCallLease(simulation) = NativeCallLease(false, UInt(0), simulation.compiled,
    simulation.environment_bindings, simulation.model.revision,
    simulation.model.runtime_revision, simulation.model.environment_revision)

# A column view stores the real canonical arrays. No initial value or mutable
# scientific value is cloned. Its erased backing preserves canonical Status
# identity and all public whole-status operations without a scene-wide type.
struct NativeStatusView{C,I}
    columns::C
    indices::I
    identity::Base.RefValue{Nothing}
    backing::Any
end
struct NativeReferenceView{S}
    status::S
end
@inline _native_status(view::NativeReferenceView) = view.status
_view_fields(view::NativeStatusView) = length(view.columns)
_view_fields(view::NativeReferenceView) = length(keys(view.status))
_view_native_fields(view::NativeStatusView) = length(view.columns)
_view_native_fields(::NativeReferenceView) = 0
_prepare_state_view(status, strategy) = strategy === :native ?
    _native_status_view(status) : NativeReferenceView(status)

function _native_status_view(status::PSE.Status)
    names = keys(status)
    # Logical keys can be erased by Status.backing. Resolve that schema once
    # on the cold path, then specialize reference gathering on its actual names.
    return _native_status_view(status, Val(names))
end

_native_canonical_reference(reference::Base.RefArray) = reference
_native_canonical_reference(reference) = throw(ArgumentError(
    "A native numerical status requires canonical column references"))

function _native_column_source(reference::Base.RefArray)
    source = getfield(reference, :x)
    source isa Vector || throw(ArgumentError("Native columns require Vector storage"))
    isconcretetype(eltype(source)) && isbitstype(eltype(source)) ||
        throw(ArgumentError("Native columns require concrete scalar isbits values"))
    return source
end

@generated function _native_status_view(status::PSE.Status,
    ::Val{Names}) where {Names}
    isempty(Names) && return :(throw(ArgumentError("Empty native status schema")))
    references = [Symbol(:canonical_reference_, index) for index in eachindex(Names)]
    loads = [:( $(references[index]) = _native_canonical_reference(
        PSE.refvalue(status, $(QuoteNode(Names[index]))))) for index in eachindex(Names)]
    columns = Expr(:tuple, [:( _native_column_source($(references[index])))
        for index in eachindex(Names)]...)
    # Preserve every exact physical index, including holes and per-field
    # allocation order differences; no scientific values are read or copied.
    indices = Expr(:tuple, [:(getfield($(references[index]), :i))
        for index in eachindex(Names)]...)
    return quote
        $(loads...)
        NativeStatusView(NamedTuple{$(QuoteNode(Names))}($columns), $indices,
            PSE._status_identity(status), status)
    end
end

@inline @generated function _native_status(view::NativeStatusView{C}) where {C}
    names = fieldnames(C)
    refs = Expr(:tuple, [:(Ref(getfield(view.columns, $i), getfield(view.indices, $i)))
        for i in eachindex(names)]...)
    return :(PSE.Status(NamedTuple{$(QuoteNode(names))}($refs),
        view.identity, view.backing))
end

include("pb_direct_status.jl")

struct NativeCallPlan{M,V,C,O}
    model::M
    view::V
    context::C
    outputs::O
    application::Any
    environment_binding::Any
    # This UnionAll field deliberately excludes the scene-wide default
    # context parameter from the numerical specialization surface.
    cache::PSE.CallContextCache
end

struct NativeCallEntry{P}
    plan::P
    targets::Any
    generation_ref::Base.RefValue{UInt64}
    generation::UInt64
end

struct NativeCallTable{E,S}
    entries::E
    original_calls::Any
    fallback_context::Any
    lease::NativeCallLease
    counters::NativeCallCounters
    status_strategy::S
end
Base.length(table::NativeCallTable) = length(table.original_calls)
Base.isempty(table::NativeCallTable) = isempty(table.original_calls)
Base.iterate(table::NativeCallTable, args...) = iterate(table.original_calls, args...)

@inline @generated function _native_entry(table::NativeCallTable{E},
    ::Val{Name}) where {E,Name}
    index = findfirst(==(Name), fieldnames(E))
    return index === nothing ? :(nothing) : :(getfield(table.entries, $index))
end

function _native_fallback_context!(context)
    original = context.calls.fallback_context
    for name in (:compiled, :environment_bindings, :application, :object_id,
        :bound_inputs, :output_targets, :temporal_streams, :output_retention,
        :time, :constants, :publication_allowed, :environment)
        setfield!(original, name, getfield(context, name))
    end
    return original
end

@inline PSE._find_call_targets(table::NativeCallTable, name::Val,
    context::PSE.RunContext) = PSE._find_call_targets(table.original_calls, name, context)
@inline PSE._find_manual_call_targets(table::NativeCallTable, name::Val,
    context::PSE.RunContext) = PSE._find_manual_call_targets(table.original_calls, name, context)
PSE._prepare_runtime_call_targets!(table::NativeCallTable, args...) =
    PSE._prepare_runtime_call_targets!(table.original_calls, args...)

@noinline function _native_fallback_call!(context, name;
    environment, sampled_environment, publish, objects)
    context.calls.counters.fallback_calls += 1
    return PSE.run_call!(_native_fallback_context!(context), name;
        environment, sampled_environment, publish, objects)
end

@inline function _native_lease_live(table)
    lease = table.lease
    return lease.running && lease.task_id == objectid(current_task())
end

@noinline function _native_advance_cache_revision!(cache::PSE.CallContextCache{C}) where {C}
    # Dispatch once on the concrete cache layout. Keeping its large default
    # context type out of the numerical plan must not box UInt64 revisions.
    cache.execution_revision += UInt64(1)
    return nothing
end

@inline function _native_run_plan!(plan::NativeCallPlan, parent, publish, sampled)
    cache = plan.cache
    # Same canonical execution revision as ordinary CallEvaluation tokens.
    # An active evaluation takes the fallback before reaching this boundary.
    _native_advance_cache_revision!(cache)
    child = plan.context
    child.time = parent.time
    child.constants = parent.constants
    child.publication_allowed = publish && parent.publication_allowed
    child.environment = parent.environment
    cache.in_use = true
    try
        status = _native_kernel_status(plan.view, plan.model, child.calls.status_strategy)
        parent.calls.counters.numerical_calls += 1
        parent.calls.counters.numerical_fields += _view_fields(plan.view)
        parent.calls.counters.native_fields += _view_native_fields(plan.view)
        if status isa NativeDirectStatus
            parent.calls.counters.direct_calls += 1
            parent.calls.counters.direct_fields += _view_fields(plan.view)
        end
        Base.@inline PSE.run!(plan.model, status, sampled, child.constants, child)
        if child.publication_allowed
            isempty(plan.outputs) || PSE._model_publish_runtime_outputs!(plan.outputs, child.time)
            PSE._record_model_call_publication!(child.output_retention,
                child.application.id, child.time)
        end
    finally
        cache.in_use = false
    end
    return nothing
end

@inline function _native_run_entry!(entry::NativeCallEntry, context, name,
    environment, sampled_environment, publish, objects)
    # All backend overrides, environment sampling, evaluations and reentrancy
    # use the original public API and original owner/cache/publication journal.
    if !(sampled_environment isa PSE.UnspecifiedModelEnvironment) &&
       environment isa PSE.NoEnvironmentOverride &&
       context.environment isa PSE.NoEnvironmentOverride && objects === nothing &&
       _native_lease_live(context.calls) && PSE._active_call_evaluation() === nothing &&
       !entry.plan.cache.in_use
        targets = CR._resolved_synchronize_view!(entry.targets, context)
        _native_run_plan!(entry.plan, context, publish, sampled_environment)
        if publish && context.publication_allowed
            for application_id in targets.binding.potential_callee_application_ids
                PSE._record_evaluated_call_clock!(nothing,
                    context.output_retention, application_id, context.time)
            end
        end
        return targets
    end
    return _native_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end
@inline _native_run_entry!(::Nothing, context, name, environment, sampled, publish, objects) =
    _native_fallback_call!(context, name; environment,
        sampled_environment=sampled, publish, objects)

@inline Base.@constprop :aggressive function PSE.run_call!(
    context::PSE.RunContext{CS,A,CT}, name::Symbol;
    environment=PSE._NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=PSE._UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false, objects=nothing,
) where {CS,A,CT<:NativeCallTable}
    if !(environment isa PSE.NoEnvironmentOverride) &&
       !(sampled_environment isa PSE.UnspecifiedModelEnvironment)
        throw(ArgumentError("`environment` and `sampled_environment` are mutually exclusive hard-call overrides."))
    end
    return _native_run_entry!(_native_entry(context.calls, Val(name)), context,
        name, environment, sampled_environment, publish, objects)
end

# A fixed graph lease is validated BEFORE invoking its audited kernels.
# Returning the typed scientific model here needs no assertion over an erased
# fallback result. Unsupported model graphs never receive this capability;
# kernels may not escape the context beyond its synchronous invocation.
@inline function _native_call_model(entry::NativeCallEntry, context, name)
    context.calls.counters.model_lookups += 1
    return entry.plan.model
end
@noinline _native_call_model(::Nothing, context, name) =
    PSE._call_model(_native_fallback_context!(context), name)
@inline PSE._call_model(context::PSE.RunContext{CS,A,CT}, name::Val) where
    {CS,A,CT<:NativeCallTable} = _native_call_model(_native_entry(context.calls, name), context, name)

function _thin_native_context(original::PSE.RunContext{CS,A,CT,BI,OT,TS,OR,C,E}, table) where
    {CS,A,CT,BI,OT,TS,OR,C,E}
    return PSE.RunContext{Any,Any,typeof(table),BI,OT,Any,OR,C,E}(
        original.compiled, original.environment_bindings, original.application,
        original.object_id, table, original.bound_inputs, original.output_targets,
        original.temporal_streams, original.output_retention, original.time,
        original.constants, original.publication_allowed, original.environment)
end

function _prepare_native_context(simulation, application, owner, lease, counters, ancestors,
    state_strategy, status_strategy)
    native_call_effects(typeof(owner.model)) === :fixed_native_calls ||
        throw(ArgumentError("unknown_model_capability"))
    isempty(owner.input_bindings) || throw(ArgumentError("temporal_input_boundary"))
    isempty(owner.output_targets) || throw(ArgumentError("distributed_output_boundary"))
    isempty(PSE.environment_outputs_(owner.model)) || throw(ArgumentError("environment_commit_boundary"))
    all(output -> output isa PSE.RuntimeOutputStream, owner.output_bindings) ||
        throw(ArgumentError("distributed_publication_boundary"))
    view = _prepare_state_view(owner.status, state_strategy)
    original = CR._resolved_original_context(simulation, application, owner)
    key = (application.id, owner.object_id)
    key in ancestors && throw(ArgumentError("recursive_call_graph"))
    push!(ancestors, key)
    names, entries = Symbol[], Any[]
    try
        for targets in original.calls
            PSE._compiled_call_mode(targets.binding) === :manual ||
                throw(ArgumentError("initializer_boundary"))
            batches = PSE._materialize_call_execution_batches!(targets)
            length(batches) == 1 && length(only(batches).targets) == 1 ||
                throw(ArgumentError("singular_fixed_call_required"))
            batch = only(batches)
            child = only(batch.targets)
            child_context, child_view = _prepare_native_context(simulation,
                batch.application, child, lease, counters, ancestors, state_strategy, status_strategy)
            plan = NativeCallPlan(child.model, child_view, child_context,
                child.output_bindings, batch.application, child.environment_binding,
                child.call_context_cache)
            push!(names, PSE._compiled_call_name(targets.binding))
            push!(entries, NativeCallEntry(plan, targets,
                getfield(targets.binding, :membership_generation),
                PSE._compiled_call_membership_generation(targets.binding)))
        end
    finally
        delete!(ancestors, key)
    end
    table = NativeCallTable(NamedTuple{Tuple(names)}(Tuple(entries)),
        original.calls, original, lease, counters, status_strategy)
    return _thin_native_context(original, table), view
end

struct NativeRootRow{M,V,C,O}
    model::M
    view::V
    context::C
    outputs::O
end
struct NativeRootBatch{R,E,A,S}
    rows::R
    environment_provider::E
    # One application's sampling metadata is concrete at the batch boundary.
    # Numerical RunContexts still erase application/compiled scene types.
    application::A
    publish::Bool
    lease::NativeCallLease
    status_strategy::S
end
struct NativeOrderedBatch{B}
    batch::B
end
struct NativeApplication{B}
    entry::Int
    application_slot::Int
    batches::B
end
mutable struct NativeCallProgram{S}
    simulation::S
    nodes::Any
    schedule::Any
    counters::NativeCallCounters
    state_strategy::Symbol
    status_strategy::Symbol
    runtime_revision::Int
    environment_revision::Int
    report::Any
    rebuilds::Int
end

function _prepare_native_root(simulation, batch, counters, state_strategy, status_strategy)
    batch isa PSE.CompiledExecutionBatch || throw(ArgumentError("unsupported_batch"))
    isempty(batch.targets) && throw(ArgumentError("empty_batch"))
    batch.environment_provider isa PSE.UnspecifiedModelEnvironment &&
        throw(ArgumentError("per_object_environment_boundary"))
    isnothing(simulation.performance) || throw(ArgumentError("instrumentation_boundary"))
    PSE._synchronize_model_execution_batch_contexts!(batch, simulation.compiled,
        simulation.environment_bindings, simulation.temporal_streams,
        simulation.output_retention, float(simulation.current_step), simulation.constants)
    lease = NativeCallLease(simulation)
    rows = map(batch.targets) do owner
        context, view = _prepare_native_context(simulation, batch.application,
            owner, lease, counters, Set{Tuple{Symbol,PSE.ObjectId}}(), state_strategy,
            status_strategy)
        NativeRootRow(owner.model, view, context, owner.output_bindings)
    end
    Row = typeof(first(rows))
    all(row -> typeof(row) === Row, rows) || throw(ArgumentError("heterogeneous_native_rows"))
    typed = Vector{Row}(rows)
    return NativeRootBatch(typed, batch.environment_provider, batch.application,
        batch.output_publication.enabled, lease, status_strategy)
end

function _native_context_membership_current(context)
    for entry in values(context.calls.entries)
        entry.generation_ref[] == entry.generation || return false
        _native_context_membership_current(entry.plan.context) || return false
    end
    return true
end
function _native_root_current(batch, simulation)
    lease = batch.lease
    model = simulation.model
    return lease.compiled === simulation.compiled &&
        lease.environment_bindings === simulation.environment_bindings &&
        model.revision == lease.model_revision && model.runtime_revision == lease.runtime_revision &&
        model.environment_revision == lease.environment_revision &&
        !PSE.bindings_dirty(model) && !PSE.environment_bindings_dirty(model) &&
        all(row -> _native_context_membership_current(row.context), batch.rows)
end

@noinline function _native_numerical_rows!(rows, environment, constants, step,
    counters, publish, lease, status_strategy)
    # Environment sampling is a control-plane operation and can erase a row's
    # type through application/window metadata. Dispatch once per numerical
    # batch on the actual sampled row and constant types, before entering the
    # original scientific kernels. Never inline this boundary into sampling.
    lease.running, lease.task_id = true, objectid(current_task())
    try
        for row in rows
            context = row.context
            context.time = float(step)
            context.constants = constants
            context.publication_allowed = true
            context.environment = PSE._NO_ENVIRONMENT_OVERRIDE
            status = _native_kernel_status(row.view, row.model, status_strategy)
            counters.roots += 1
            counters.numerical_fields += _view_fields(row.view)
            counters.native_fields += _view_native_fields(row.view)
            if status isa NativeDirectStatus
                counters.direct_roots += 1
                counters.direct_fields += _view_fields(row.view)
            end
            Base.@inline PSE.run!(row.model, status, environment, constants, context)
            publish && PSE._model_publish_runtime_outputs!(row.outputs, step)
        end
    finally
        lease.running, lease.task_id = false, UInt(0)
    end
    return nothing
end
@inline function _run_native_batch!(batch::NativeRootBatch, simulation, step, counters)
    # The enclosing application validates every native batch before executing
    # any row. A stale application falls back once, never once per old batch.
    environment = PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings, batch.application, step)
    _native_numerical_rows!(batch.rows, environment, simulation.constants, step,
        counters, batch.publish, batch.lease, batch.status_strategy)
    return nothing
end
@inline function _run_native_batch!(batch::NativeOrderedBatch, simulation, step, counters)
    GP._program_run_original_batch!(batch.batch, simulation, step)
    counters.ordinary_batches += 1
    return nothing
end
_native_batch_current(::NativeOrderedBatch, simulation) = true
_native_batch_current(batch::NativeRootBatch, simulation) = _native_root_current(batch, simulation)
@inline _native_batches_current(::Tuple{}, simulation) = true
@inline _native_batches_current(batches::Tuple, simulation) =
    _native_batch_current(first(batches), simulation) &&
        _native_batches_current(Base.tail(batches), simulation)

@noinline function _native_run_current_group!(simulation, slot, step, counters)
    group = simulation.execution_plan.groups_by_application_slot[slot]
    if group !== nothing
        PSE._run_model_execution_group!(group, simulation, step, simulation.performance)
        counters.ordinary_batches += length(group.batches)
    end
    return nothing
end

@generated function _run_native_batches!(batches::B, simulation, step, counters) where {B<:Tuple}
    return Expr(:block, [:( _run_native_batch!(getfield(batches, $i), simulation, step, counters))
        for i in 1:fieldcount(B)]..., :(nothing))
end
@generated function _run_native_nodes!(nodes::N, simulation, step, schedule, counters) where {N<:Tuple}
    body = Expr[]
    for index in 1:fieldcount(N)
        push!(body, quote
            node = getfield(nodes, $index)
            if CR._region_entry_due(schedule, node.entry, step)
                if changed
                    _native_run_current_group!(simulation, node.application_slot, step, counters)
                elseif !_native_batches_current(node.batches, simulation)
                    counters.root_guard_failures += 1
                    _native_run_current_group!(simulation, node.application_slot, step, counters)
                else
                    _run_native_batches!(node.batches, simulation, step, counters)
                end
                if PSE._simulation_runtime_dirty(simulation, simulation.performance)
                    completed = GP._program_refresh_after!(simulation, schedule, completed, node.entry)
                    changed = true
                end
            end
        end)
    end
    return quote
        changed, completed = false, nothing
        $(body...)
        nothing
    end
end

function _compile_native_call_plan!(program)
    simulation, counters = program.simulation, program.counters
    PSE._compiled_source_finalize!(simulation)
    schedule = simulation.compiled.scenario_plan.application_schedule
    nodes, reasons, applications = Any[], NamedTuple[], Symbol[]
    selected_rows = selected_batches = native_fields = edges = 0
    for (index, entry) in enumerate(schedule.entries)
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        batches = Any[]
        if group !== nothing
            for batch in group.batches
                selected, reason = nothing, :eligible
                try
                    selected = _prepare_native_root(simulation, batch, counters,
                        program.state_strategy, Val(program.status_strategy))
                catch error_
                    error_ isa ArgumentError || rethrow()
                    reason = Symbol(error_.msg)
                end
                if selected === nothing
                    push!(batches, NativeOrderedBatch(batch))
                else
                    push!(batches, selected)
                    selected_batches += 1
                    selected_rows += length(selected.rows)
                    native_fields += sum(row -> _view_native_fields(row.view), selected.rows)
                    push!(applications, batch.application.id)
                    function count_edges(context)
                        sum(entry -> 1 + count_edges(entry.plan.context),
                            values(context.calls.entries); init=0)
                    end
                    edges += sum(row -> count_edges(row.context), selected.rows)
                end
                push!(reasons, (application=batch.application.id, reason))
            end
        end
        push!(nodes, NativeApplication(index, entry.application_slot, Tuple(batches)))
    end
    program.nodes, program.schedule = Tuple(nodes), schedule
    program.runtime_revision = simulation.runtime_revision
    program.environment_revision = simulation.environment_bindings.environment_revision
    program.report = (selected_applications=Tuple(unique(applications)),
        native_batches=selected_batches, native_root_memberships=selected_rows,
        native_call_edges=edges, native_column_fields=native_fields, reasons=Tuple(reasons),
        scalar_value_copies=false, canonical_references_replaced=false,
        cached_owner_type_graphs_in_native_context=false,
        fixed_graph_capability=:fixed_native_calls,
        unsupported_features=:ordinary_executor_or_original_call_context,
        model_type_assertions=false, state_strategy=program.state_strategy,
        status_strategy=program.status_strategy, direct_status_bounds=:checked)
    return program
end

function compile_native_call_driver(simulation; state_strategy::Symbol=:native,
    status_strategy::Symbol=:refs)
    state_strategy in (:native, :references) || throw(ArgumentError(
        "state_strategy must be :native or :references"))
    status_strategy in (:refs, :direct) || throw(ArgumentError(
        "status_strategy must be :refs or :direct"))
    program = NativeCallProgram(simulation, (), nothing, NativeCallCounters(), state_strategy,
        status_strategy, -1, -1, nothing, 0)
    return _compile_native_call_plan!(program)
end
function _ensure_native_call_plan!(program)
    simulation = program.simulation
    PSE._compiled_source_finalize!(simulation)
    if program.runtime_revision != simulation.runtime_revision ||
       program.environment_revision != simulation.environment_bindings.environment_revision
        _compile_native_call_plan!(program)
        program.rebuilds += 1
    end
    return program
end
function advance_native_call_driver!(program; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    simulation = program.simulation
    if simulation.performance !== nothing
        PSE.continue!(simulation; steps)
        return simulation
    end
    for _ in 1:steps
        _ensure_native_call_plan!(program)
        step = simulation.current_step + 1
        simulation.compiled.execution_generation += UInt64(1)
        empty!(simulation.environment_bindings.sample_cache)
        PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
            program.schedule, Int(step))
        _run_native_nodes!(program.nodes, simulation, step, program.schedule, program.counters)
        simulation.current_step = step
    end
    _ensure_native_call_plan!(program)
    return simulation
end
function native_call_driver_report(program)
    counters = program.counters
    return merge(program.report, (current_step=program.simulation.current_step,
        executed_numerical_roots=counters.roots, executed_numerical_calls=counters.numerical_calls,
        executed_numerical_fields=counters.numerical_fields,
        executed_native_column_fields=counters.native_fields,
        executed_direct_roots=counters.direct_roots,
        executed_direct_calls=counters.direct_calls,
        executed_direct_fields=counters.direct_fields,
        typed_model_lookups=counters.model_lookups, fallback_calls=counters.fallback_calls,
        ordinary_batch_executions=counters.ordinary_batches,
        root_guard_failures=counters.root_guard_failures, rebuilds=program.rebuilds))
end

"""The CR fixture's exact model/forcing inputs, with optional native construction."""
function pb_native_fixture(; native::Bool=true, nobjects::Int=4, steps::Int=2,
    heterogeneous::Bool=false)
    nobjects > 0 && steps > 0 || throw(ArgumentError("positive objects/steps required"))
    storage = native ? PSE.NativeColumnStorage() : nothing
    objects = [PSE.Object(index; kind=:gas_exchange_unit, scale=:diagnostic_unit,
        status=merge((Ra_SW_f=150.0 + mod(index, 7), sky_fraction=0.8,
            aPPFD=(150.0 + mod(index, 7)) * 0.48 * 4.57, d=0.03),
            heterogeneous && index == 1 ? (spare=1.0,) : (;)))
        for index in 1:nobjects]
    forcing = PlantMeteo.Weather([
        PlantMeteo.Atmosphere(T=24.0 + 0.25 * mod(step - 1, 5), Wind=1.5,
            P=101.325, Rh=0.65, Cₐ=410.0, duration=Hour(1)) for step in 1:steps])
    applications = (
        PSE.ModelSpec(PB.Monteith(); name=:energy,
            on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)),
        PSE.ModelSpec(PB.Fvcb(); name=:photosynthesis,
            on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)),
        PSE.ModelSpec(PB.Medlyn(0.03, 12.0); name=:stomata,
            on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)))
    model = native ? PSE.CompositeModel(objects...; applications,
        environment=forcing, status_storage=storage) :
        PSE.CompositeModel(objects...; applications, environment=forcing)
    return (; model, storage, native, nobjects, steps)
end

function pb_native_driver_checks(; nobjects::Int=4, steps::Int=2)
    reference = PSE.run!(CR.pb_many_fixture(; nobjects, steps); steps=0, outputs=:all)
    fixture = pb_native_fixture(; native=true, nobjects, steps)
    simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
    canonical_status = PSE.model_status(fixture.model, 1)
    external_ref = PSE.refvalue(canonical_status, :Ra_SW_f)
    program = compile_native_call_driver(simulation)
    initial = native_call_driver_report(program)
    @test initial.native_root_memberships > 0
    @test initial.native_call_edges > 0
    @test initial.native_column_fields > 0
    PSE.continue!(reference; steps)
    advance_native_call_driver!(program; steps)
    @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
    @test canonical_status === PSE.model_status(fixture.model, 1)
    @test external_ref === PSE.refvalue(PSE.model_status(fixture.model, 1), :Ra_SW_f)
    final = native_call_driver_report(program)
    @test final.executed_numerical_roots == nobjects * steps
    @test final.executed_numerical_calls > 0
    @test final.typed_model_lookups > 0
    @test final.executed_numerical_fields > 0
    @test final.fallback_calls == 0
    @test final.ordinary_batch_executions == 0
    return (passed=true, initial, final,
        counts=CR.downstream_work_report(simulation,
            [object.id for object in PSE.model_objects(fixture.model)]),
        storage=PSE.native_storage_report(fixture.storage),
        scientific_kernels=:original_unmodified_methods,
        compared=:all_final_states_and_raw_retained_histories)
end

include("pb_driver_checks.jl")

end
