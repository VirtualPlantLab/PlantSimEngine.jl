# Experimental compiler, deliberately outside the package load path. Kernels
# remain the original Julia run! methods. Neither selectors nor biology names
# participate in lowering decisions.

"""
    program_effects(::Type) = :ordered

Experimental effect promise used solely by this benchmark compiler. `:local`
means a kernel reads scalar parameters, constants, its environment row, and its
passed Status, and mutates only that Status. It must not observe context,
identity, execution order, other rows, global state, RNGs, shared mutable model
caches, or escaped references. Reads through model/environment/constants must
not indirectly reach or alias Status cells. It also promises completion without
throwing for the scenario's validated inputs: row-major execution can otherwise expose a
different partially advanced scene after a kernel failure. Fallible or
unregistered models retain application ordering. Violating this experimental
author promise does not guarantee equivalent failed-run partial state.
"""
program_effects(::Type) = :ordered

struct ProgramDirectBatch{B,S,O}
    batch::B
    statuses::S
    output_bindings::O
end

struct ProgramApplication{B}
    first_entry::Int
    last_entry::Int
    application_slot::Int
    batches::B
    direct::Bool
end

struct ProgramFusedRegion{B}
    first_entry::Int
    last_entry::Int
    batches::B
end

struct ProgramPlan{N,S,P,R}
    nodes::N
    schedule::S
    packed_store::P
    runtime_revision::Int
    fixed_local::Bool
    report::R
end

mutable struct GeneratedProgram{S}
    simulation::S
    plan::Any
    strategy::Symbol
    packed::Bool
    block_size::Int
    rebuilds::Int
end

program_simulation(program::GeneratedProgram) = program.simulation

function _program_same_status_references(left, right)
    keys(left) == keys(right) || return false
    return all(name -> PSE.refvalue(left, name) === PSE.refvalue(right, name), keys(left))
end

# RawGlobal is a routing choice, not proof that custom Tables/iterator row
# access is pure. Only ordinary scalar values and prepared concrete row vectors
# can participate in reordering or deferred canonical writeback. Values are
# reread on each advance; model/environment effects cannot mutate them inside it.
function _program_pure_environment_provider(provider)
    isnothing(provider) && return true
    provider isa PSE.RawGlobalModelEnvironment || return false
    source = provider.sampled_environment
    source isa NamedTuple && isbitstype(typeof(source)) && return true
    source isa Vector && eltype(source) <: NamedTuple && isbitstype(eltype(source)) && return true
    if source isa PSE.PreparedGlobalEnvironmentRows
        rows = source.rows
        return rows isa Vector && eltype(rows) <: NamedTuple && isbitstype(eltype(rows))
    end
    return false
end

"""Cheap provider classification gates; custom tables retain ordered sampling."""
function program_provider_checks()
    scalar = (driver=1.0, duration=Hour(1))
    rows = [scalar, scalar]
    @test _program_pure_environment_provider(nothing)
    @test _program_pure_environment_provider(PSE.RawGlobalModelEnvironment(scalar))
    @test _program_pure_environment_provider(PSE.RawGlobalModelEnvironment(rows))
    @test _program_pure_environment_provider(PSE.RawGlobalModelEnvironment(
        PSE.PreparedGlobalEnvironmentRows(rows)))
    @test !_program_pure_environment_provider(PSE.RawGlobalModelEnvironment((driver=Ref(1.0),)))
    @test !_program_pure_environment_provider(PSE.RawGlobalModelEnvironment(
        PSE.PreparedGlobalEnvironmentRows(Any[scalar])))
    @test !_program_pure_environment_provider(PSE.RawGlobalModelEnvironment(Ref(scalar)))
    return (passed=true, cases=7, custom_sources=:ordered_sampling_boundary)
end

function _program_direct_reason(simulation, group)
    isnothing(simulation.performance) || return :performance_instrumentation
    isempty(group.batches) && return :empty_application
    for batch in group.batches
        # Custom/global/spatial row sampling can have effects or hidden status
        # reads and therefore remains at its ordinary batch boundary.
        _program_pure_environment_provider(batch.environment_provider) ||
            return :environment_sampling_boundary
        for target in batch.targets
            program_effects(typeof(target.model)) === :local || return :unknown_effects
            isempty(target.call_bindings) || return :manual_or_initializer_calls
            isempty(target.input_bindings) || return :temporal_materialization
            isempty(target.bound_inputs) || return :bound_many_inputs
            isempty(target.output_targets) || return :distributed_outputs
            _program_same_status_references(target.status, target.canonical_status) ||
                return :noncanonical_status_view
            all(name -> PSE.refvalue(target.canonical_status, name) isa Base.RefValue,
                keys(target.canonical_status)) || return :unsupported_reference_alias_proof
            all(name -> isbitstype(typeof(target.status[name])), keys(target.status)) ||
                return :mutable_status_values
            all(output -> output isa PSE.RuntimeOutputStream, target.output_bindings) ||
                return :distributed_publication
        end
    end
    return :eligible
end

function _program_cross_row_aliases(groups)
    owners = IdDict{Any,Any}()
    for group in groups
        isnothing(group) && continue
        for batch in group.batches, target in batch.targets
            for name in keys(target.status)
                reference = PSE.refvalue(target.status, name)
                if haskey(owners, reference)
                    owners[reference] == target.object_id || return true
                else
                    owners[reference] = target.object_id
                end
            end
        end
    end
    return false
end

function _program_packed_output(output::PSE.RuntimeOutputStream{V}, status) where {V}
    reference = PSE.refvalue(status, V)
    return PSE.RuntimeOutputStream{V,typeof(output.stream),typeof(reference)}(
        output.stream, reference, output.dependency_horizon,
    )
end

function _program_concrete_vector(values)
    isempty(values) && return values
    T = typeof(first(values))
    all(value -> typeof(value) === T, values) || throw(ArgumentError(
        "A compiled direct batch must have homogeneous row payload types.",
    ))
    return Vector{T}(values)
end

function _program_direct_batch(batch, store)
    if isnothing(store)
        statuses = [target.status for target in batch.targets]
        bindings = [target.output_bindings for target in batch.targets]
    else
        statuses = [packed_status(store, target.status, row)
            for (row, target) in enumerate(batch.targets)]
        bindings = [map(output -> _program_packed_output(output, statuses[row]),
            target.output_bindings) for (row, target) in enumerate(batch.targets)]
    end
    return ProgramDirectBatch(batch, _program_concrete_vector(statuses),
        _program_concrete_vector(bindings))
end

_program_cadence_key(entry) = (entry.dt, entry.phase, entry.kind,
    entry.period_steps, entry.phase_step)

@inline function _program_entry_due(schedule, index, step)
    entry = schedule.entries[index]
    entry.kind === :always && return true
    if entry.kind === :periodic_integer
        return mod(step - something(entry.phase_step), something(entry.period_steps)) == 0
    end
    return PSE._generic_schedule_entry_is_due(entry, Int(step))
end

function _program_compatible(left::ProgramApplication, right::ProgramApplication, schedule)
    left.direct && right.direct || return false
    length(left.batches) == length(right.batches) == 1 || return false
    _program_cadence_key(schedule.entries[left.last_entry]) ==
        _program_cadence_key(schedule.entries[right.first_entry]) || return false
    a, b = only(left.batches).batch.targets, only(right.batches).batch.targets
    length(a) == length(b) || return false
    return all(index -> a[index].object_id == b[index].object_id, eachindex(a))
end

function _compile_program_plan(simulation, strategy, want_packed, block_size)
    schedule = simulation.compiled.scenario_plan.application_schedule
    groups = [simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        for entry in schedule.entries]
    reasons = [isnothing(group) ? :empty_application :
        _program_direct_reason(simulation, group) for group in groups]
    if _program_cross_row_aliases(groups)
        # Whole-program alias proof: an eligible kernel may otherwise write a
        # row that a later application regards as belonging to another object.
        reasons = [reason === :eligible ? :cross_row_alias : reason for reason in reasons]
    end
    all_local = all(reason -> reason in (:eligible, :empty_application), reasons)
    store = nothing
    packed_reason = want_packed ? :requires_complete_local_scene : :not_requested
    if want_packed && all_local && !isempty(groups)
        nonempty = [group for group in groups if !isnothing(group) && !isempty(group.batches)]
        compatible = !isempty(nonempty) && all(group -> length(group.batches) == 1, nonempty)
        if compatible
            reference_targets = only(first(nonempty).batches).targets
            compatible = all(group -> begin
                targets = only(group.batches).targets
                length(targets) == length(reference_targets) &&
                    all(i -> targets[i].object_id == reference_targets[i].object_id &&
                        _program_same_status_references(targets[i].status, reference_targets[i].status),
                        eachindex(targets))
            end, nonempty)
            if compatible
                try
                    store = prepare_packed_rows([target.canonical_status for target in reference_targets])
                    packed_reason = :eligible
                catch error_
                    error_ isa ArgumentError || rethrow()
                    packed_reason = :unsupported_packed_schema
                end
            end
        end
        !compatible && (packed_reason = :different_memberships_or_status_schemas)
    end
    applications = Any[]
    for (index, group) in enumerate(groups)
        if isnothing(group)
            push!(applications, ProgramApplication(index, index,
                schedule.entries[index].application_slot, (), false))
        elseif reasons[index] === :eligible
            batches = Tuple(_program_direct_batch(batch, store) for batch in group.batches)
            push!(applications, ProgramApplication(index, index, group.application.slot, batches, true))
        else
            push!(applications, ProgramApplication(index, index, group.application.slot,
                Tuple(group.batches), false))
        end
    end
    nodes = Any[]
    index = 1
    while index <= length(applications)
        first_application = applications[index]
        stop = index
        limit = strategy === :monolith ? length(applications) : block_size
        if strategy !== :typed
            while stop < length(applications) && stop - index + 1 < limit &&
                  _program_compatible(applications[stop], applications[stop + 1], schedule)
                stop += 1
            end
        end
        if stop > index
            push!(nodes, ProgramFusedRegion(index, stop,
                Tuple(only(applications[j].batches) for j in index:stop)))
        else
            push!(nodes, first_application)
        end
        index = stop + 1
    end
    report = (
        strategy,
        applications=length(applications),
        direct_applications=count(==(:eligible), reasons),
        ordered_applications=count(reason -> !(reason in (:eligible, :empty_application)), reasons),
        environment_barrier_applications=count(==(:environment_sampling_boundary), reasons),
        reasons=Tuple((application=schedule.entries[i].application_id, reason=reasons[i])
            for i in eachindex(reasons)),
        fused_regions=count(node -> node isa ProgramFusedRegion, nodes),
        fused_applications=sum(node -> node isa ProgramFusedRegion ?
            node.last_entry - node.first_entry + 1 : 0, nodes; init=0),
        packed_requested=want_packed,
        packed_selected=!isnothing(store),
        packed_reason,
        packed_layout=isnothing(store) ? nothing : packed_report(store),
        local_effect_contract=:total_nonescaping_disjoint_status_only,
        monolith_requested=strategy === :monolith,
        monolith_selected=strategy === :monolith && all_local,
        block_size,
        node_types=Tuple(string(nameof(typeof(node))) for node in nodes),
    )
    return ProgramPlan(Tuple(nodes), schedule, store, simulation.runtime_revision, all_local, report)
end

"""Compile resolved application/batch calls; unknown effects remain ordered barriers."""
function compile_program(simulation; strategy::Symbol=:typed, packed::Bool=false, block_size::Int=4)
    strategy in (:typed, :fused, :monolith) || throw(ArgumentError("Unknown strategy $strategy"))
    block_size > 0 || throw(ArgumentError("block_size must be positive"))
    PSE._compiled_source_finalize!(simulation)
    plan = _compile_program_plan(simulation, strategy, packed, block_size)
    return GeneratedProgram(simulation, plan, strategy, packed, block_size, 0)
end

function strategy_report(program::GeneratedProgram)
    return merge(program.plan.report, (rebuilds=program.rebuilds,
        current_step=program.simulation.current_step))
end

@inline function _program_run_original_batch!(batch, simulation, step)
    if isnothing(simulation.performance)
        PSE._run_model_execution_batch!(batch, simulation.compiled,
            simulation.environment_bindings, step, simulation.constants,
            simulation.temporal_streams, simulation.output_retention)
    else
        PSE._run_model_execution_batch_profiled!(batch, simulation.compiled,
            simulation.environment_bindings, step, simulation.constants,
            simulation.temporal_streams, simulation.output_retention, simulation.performance)
        PSE._runtime_performance_count!(simulation.performance, :execution_batches_visited)
        PSE._runtime_performance_count!(simulation.performance, :execution_targets_visited,
            length(batch.targets))
    end
    return nothing
end

@inline function _program_direct_environment(batch::ProgramDirectBatch, simulation, step)
    return PSE._model_execution_batch_environment(batch.batch.environment_provider,
        simulation.environment_bindings, batch.batch.application, step)
end

@inline function _program_run_direct_row!(batch::ProgramDirectBatch, row, environment, simulation, step)
    @inbounds target = batch.batch.targets[row]
    context = target.context
    context isa PSE.RunContext && (context.time = float(step))
    @inbounds PSE.run!(target.model, batch.statuses[row], environment,
        simulation.constants, context)
    if batch.batch.output_publication.enabled
        @inbounds PSE._model_publish_runtime_outputs!(batch.output_bindings[row], step)
    end
    return nothing
end

@inline function _program_run_batch!(batch::ProgramDirectBatch, simulation, step)
    environment = _program_direct_environment(batch, simulation, step)
    for row in eachindex(batch.batch.targets)
        _program_run_direct_row!(batch, row, environment, simulation, step)
    end
    return nothing
end
@inline _program_run_batch!(batch, simulation, step) =
    _program_run_original_batch!(batch, simulation, step)

@generated function _program_run_batches!(batches::B, simulation, step) where {B<:Tuple}
    return Expr(:block,
        [:( _program_run_batch!(getfield(batches, $i), simulation, step))
            for i in 1:fieldcount(B)]..., :(nothing))
end

@inline function _program_run_application!(node::ProgramApplication, simulation, step)
    isempty(node.batches) && return nothing
    PSE._runtime_performance_count!(simulation.performance, :application_groups_considered)
    _program_run_batches!(node.batches, simulation, step)
    PSE._runtime_performance_count!(simulation.performance, :application_groups_visited)
    return nothing
end

# Bounded fusion deliberately retains a reusable native function boundary.
@noinline function _program_run_fused!(node::ProgramFusedRegion, simulation, step)
    _program_run_fused_body!(node.batches, simulation, step)
    return nothing
end

@generated function _program_run_fused_body!(batches::B, simulation, step) where {B<:Tuple}
    count = fieldcount(B)
    environments = [Symbol(:environment_, i) for i in 1:count]
    setup = [:( $(environments[i]) = _program_direct_environment(getfield(batches, $i), simulation, step))
        for i in 1:count]
    calls = [:( _program_run_direct_row!(getfield(batches, $i), row,
        $(environments[i]), simulation, step)) for i in 1:count]
    return quote
        $(setup...)
        for row in eachindex(getfield(batches, 1).batch.targets)
            $(calls...)
        end
        nothing
    end
end

@inline _program_run_node!(node::ProgramApplication, simulation, step) =
    _program_run_application!(node, simulation, step)
@inline _program_run_node!(node::ProgramFusedRegion, simulation, step) =
    _program_run_fused!(node, simulation, step)

function _program_refresh_after!(simulation, schedule, completed, last_entry)
    if isnothing(completed)
        completed = Set{Symbol}()
    end
    PSE._mark_schedule_prefix_completed!(completed, schedule, 1, last_entry)
    lifecycle = PSE._pending_output_request_lifecycle_delta(simulation.model)
    PSE._refresh_simulation_runtime!(simulation)
    PSE._refresh_output_request_targets!(simulation, lifecycle, completed)
    empty!(simulation.environment_bindings.sample_cache)
    return completed
end

function _program_run_fallback_node!(node, simulation, step, schedule, due, completed)
    for index in node.first_entry:node.last_entry
        _program_entry_due(schedule, index, step) || continue
        group = simulation.execution_plan.groups_by_application_slot[
            schedule.entries[index].application_slot]
        isnothing(group) || PSE._run_model_execution_group!(group,
            simulation, step, simulation.performance)
        if PSE._simulation_runtime_dirty(simulation, simulation.performance)
            completed = _program_refresh_after!(simulation, schedule, completed, index)
        end
    end
    return completed
end

@generated function _program_step_nodes!(nodes::N, simulation, step, schedule, due) where {N<:Tuple}
    blocks = Expr[]
    for i in 1:fieldcount(N)
        push!(blocks, quote
            node = getfield(nodes, $i)
            if _program_entry_due(schedule, node.first_entry, step)
                if changed
                    completed = _program_run_fallback_node!(node, simulation,
                        step, schedule, due, completed)
                else
                    _program_run_node!(node, simulation, step)
                    if PSE._simulation_runtime_dirty(simulation, simulation.performance)
                        completed = _program_refresh_after!(simulation,
                            schedule, completed, node.last_entry)
                        changed = true
                    end
                end
            end
        end)
    end
    return quote
        changed = false
        completed = nothing
        $(blocks...)
        nothing
    end
end

@inline function _program_begin_step!(simulation, plan, step)
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    due = PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
        plan.schedule, Int(step))
    PSE._runtime_performance_count!(simulation.performance, :application_schedule_dispatches)
    PSE._runtime_performance_count!(simulation.performance, :application_schedule_entries_due, length(due))
    PSE._runtime_performance_count!(simulation.performance, :application_schedule_generic_checks,
        length(plan.schedule.generic_entry_indices))
    return due
end

function _program_step!(simulation, plan, step)
    started_at = PSE._runtime_performance_start(simulation.performance)
    due = _program_begin_step!(simulation, plan, step)
    _program_step_nodes!(plan.nodes, simulation, step, plan.schedule, due)
    simulation.current_step = step
    PSE._runtime_performance_finish!(simulation.performance, :step_execution, started_at)
    PSE._runtime_performance_count!(simulation.performance, :steps_executed)
    return nothing
end

# A true one-entry-point static program: generated code contains the time loop,
# application statements and fused row loops. The number/identity of objects is
# always loop data. Unlike bounded regions it emits each local body at this site.
@generated function _program_advance_monolith!(simulation, plan::P, steps) where {P<:ProgramPlan}
    N = fieldtype(P, :nodes)
    statements = Expr[]
    for i in 1:fieldcount(N)
        NT = fieldtype(N, i)
        if NT <: ProgramFusedRegion
            B = fieldtype(NT, :batches)
            k = fieldcount(B)
            envnames = [Symbol(:env_, i, :_, j) for j in 1:k]
            setup = [:( $(envnames[j]) = _program_direct_environment(getfield(node.batches, $j), simulation, step)) for j in 1:k]
            calls = [:( Base.@inline _program_run_direct_row!(getfield(node.batches, $j), row,
                $(envnames[j]), simulation, step)) for j in 1:k]
            body = quote
                $(setup...)
                for row in eachindex(getfield(node.batches, 1).batch.targets)
                    $(calls...)
                end
            end
        else
            body = :( _program_run_application!(node, simulation, step))
        end
        push!(statements, quote
            node = getfield(plan.nodes, $i)
            if _program_entry_due(plan.schedule, node.first_entry, step)
                $body
            end
        end)
    end
    return quote
        first_step = simulation.current_step + 1
        final_step = simulation.current_step + steps
        for step in first_step:final_step
            due = _program_begin_step!(simulation, plan, step)
            $(statements...)
            simulation.current_step = step
        end
        simulation
    end
end

function _program_advance_fixed!(simulation, plan, steps)
    first_step = simulation.current_step + 1
    final_step = simulation.current_step + steps
    for step in first_step:final_step
        _program_step!(simulation, plan, step)
    end
    return simulation
end

function _program_ensure_plan!(program)
    simulation = program.simulation
    PSE._compiled_source_finalize!(simulation)
    if program.plan.runtime_revision != simulation.runtime_revision
        program.plan = _compile_program_plan(simulation, program.strategy,
            program.packed, program.block_size)
        program.rebuilds += 1
    end
    return program.plan
end

"""Advance the same Simulation timeline, retaining normal feature barriers."""
function advance_program!(program::GeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    simulation = program.simulation
    plan = _program_ensure_plan!(program)
    if plan.fixed_local
        isnothing(plan.packed_store) || pull_packed!(plan.packed_store)
        try
            if program.strategy === :monolith
                _program_advance_monolith!(simulation, plan, steps)
            else
                _program_advance_fixed!(simulation, plan, steps)
            end
        finally
            # Canonical status remains the externally observable state, including
            # after exceptions and between continuation calls.
            isnothing(plan.packed_store) || push_packed!(plan.packed_store)
        end
    else
        # Effects may mutate topology during an application. Finish that step
        # through fresh ordinary groups, then lower the updated plan next step.
        for _ in 1:steps
            plan = _program_ensure_plan!(program)
            _program_step!(simulation, plan, simulation.current_step + 1)
        end
    end
    PSE._compiled_source_finalize!(simulation)
    return simulation
end
