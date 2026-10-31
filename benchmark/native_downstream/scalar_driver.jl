module NativeScalarDriver

using PlantSimEngine
using Test
const PSE = PlantSimEngine
if !isdefined(Main, :CompiledRegionsExperiment)
    Base.include(Main, joinpath(@__DIR__, "../compiled_regions/CompiledRegionsExperiment.jl"))
end
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP

mutable struct NativeScalarCounters
    driver_batches::Int
    driver_rows::Int
    native_batches::Int
    native_rows::Int
    native_fields::Int
    native_newborn_rows::Int
    ordered_batches::Int
    lifecycle_fallback_groups::Int
end
NativeScalarCounters() = NativeScalarCounters(0, 0, 0, 0, 0, 0, 0, 0)

struct NativeScalarBatch{A,K,D,I}
    application::A
    kernel::K
    data::D
    object_ids::I
    newborn_rows::Int
end

# Keep ordinary context/owner graphs outside the generated numerical plan's
# type. The semantic execution plan already owns this exact batch instance.
struct ScalarOrderedBatch
    batch::Any
end

function _scalar_thin_context(original::PSE.RunContext{CS,A,CT,BI,OT,TS,OR,C,E}) where
    {CS,A,CT,BI,OT,TS,OR,C,E}
    return PSE.RunContext{Any,Any,Any,Any,Any,Any,Any,C,E}(
        original.compiled, original.environment_bindings, original.application,
        original.object_id, original.calls, original.bound_inputs, original.output_targets,
        original.temporal_streams, original.output_retention, original.time,
        original.constants, original.publication_allowed, original.environment)
end

function _scalar_kernel(batch, context_strategy)
    # The existing explicit capability forbids context observation and
    # representation-dependent dispatch. Preserve the actual RunContext API
    # and every field value; erase only scene-wide field type parameters.
    targets = batch.targets
    first_target = first(targets)
    original = first_target.context
    context_strategy === :thin && original isa PSE.RunContext &&
        all(target -> CR.region_effects(typeof(target.model)) === :local_ports,
            targets) || return CR._region_kernel(batch)
    all(target -> typeof(target.context) === typeof(original), targets) ||
        throw(ArgumentError("Region kernels require one context dispatch type."))
    model = first_target.model
    models = all(target -> target.model === model, targets) ?
        GP.SharedColumnModel(model) :
        GP.PerRowColumnModels(GP._program_concrete_vector([target.model for target in targets]))
    # Construct the narrow context before constructing a ColumnKernel type.
    # An intermediate kernel parameterized by the whole scene's RunContext
    # would immediately be discarded and still incur cold type assembly.
    context = _scalar_thin_context(original)
    publish = batch.output_publication.enabled
    bindings = publish ?
        GP._program_concrete_vector([target.output_bindings for target in targets]) : nothing
    return GP.ColumnKernel{publish,typeof(models),typeof(context),
        typeof(batch.environment_provider),typeof(bindings)}(
        models, context, batch.environment_provider, bindings)
end

function _scalar_has_thin_context(batch::NativeScalarBatch)
    context = batch.kernel.context
    context isa PSE.RunContext || return false
    return all(name -> fieldtype(typeof(context), name) === Any,
        (:compiled, :application, :calls, :bound_inputs, :output_targets,
            :temporal_streams, :output_retention))
end

struct NativeScalarApplication{B}
    entry::Int
    application_slot::Int
    batches::B
end

mutable struct NativeScalarPlan{N,S,R}
    nodes::N
    schedule::S
    runtime_revision::Int
    environment_revision::Int
    report::R
end

mutable struct NativeScalarProgram{S,I}
    simulation::S
    initial_ids::I
    plan::Any
    counters::NativeScalarCounters
    state_strategy::Symbol
    rebuilds::Int
end

function _scalar_native_column(references)
    isempty(references) && throw(ArgumentError("empty native column"))
    first_ref = first(references)
    first_ref isa Base.RefArray || throw(ArgumentError("non-native reference"))
    source = getfield(first_ref, :x)
    source isa Vector && isbitstype(eltype(source)) ||
        throw(ArgumentError("non-scalar canonical vector"))
    all(reference -> reference isa Base.RefArray && getfield(reference, :x) === source,
        references) || throw(ArgumentError("heterogeneous canonical owners"))
    indices = [getfield(reference, :i) for reference in references]
    # Subsets, arbitrary order, broadcasts and holes borrow their exact live
    # cells. A view contains row indices, never a duplicate scalar column.
    return indices == collect(1:length(indices)) ? source : view(source, indices)
end

function _scalar_native_batch(batch, names, target_range, context_strategy, initial_ids)
    targets = batch.targets[target_range]
    arrays = NamedTuple{names}(map(names) do name
        _scalar_native_column([PSE.refvalue(target.status, name) for target in targets])
    end)
    recipe = GP.LocalStateRecipe{names,ntuple(identity, length(names))}()
    data = GP.ColumnData(arrays, recipe, length(targets))
    kernel_input = (targets=targets, output_publication=batch.output_publication,
        environment_provider=batch.environment_provider)
    kernel = _scalar_kernel(kernel_input, context_strategy)
    ids = [target.object_id for target in targets]
    # Membership is immutable for this lowered batch. Every topology refresh
    # rebuilds it, so executed newborn coverage needs no per-step ID census.
    newborn_rows = count(id -> !(id in initial_ids), ids)
    return NativeScalarBatch(batch.application, kernel, data, ids, newborn_rows)
end

function _scalar_reference_batch(batch, names, writes, context_strategy)
    data = CR.prepare_region_reference_state(batch.targets, names, writes).data
    kernel = _scalar_kernel(batch, context_strategy)
    ids = [target.object_id for target in batch.targets]
    return NativeScalarBatch(batch.application, kernel, data, ids, 0)
end

function _scalar_owner_signature(target, names)
    signature = Any[]
    for name in names
        reference = PSE.refvalue(target.status, name)
        reference isa Base.RefArray || return nothing
        source = getfield(reference, :x)
        source isa Vector && isbitstype(eltype(source)) || return nothing
        push!(signature, source)
    end
    return Tuple(signature)
end

_scalar_same_owners(left, right) = !isnothing(left) && !isnothing(right) &&
    length(left) == length(right) && all(pair -> pair[1] === pair[2], zip(left, right))

function _scalar_prepare_batch(batch, names, context_strategy, initial_ids)
    # Separate contiguous cohorts without changing object execution order.
    # The complete batch falls back if any row lacks genuine native ports.
    signatures = [_scalar_owner_signature(target, names) for target in batch.targets]
    any(isnothing, signatures) && throw(ArgumentError("non-native declared port"))
    ranges = UnitRange{Int}[]
    start = 1
    for row in 2:length(signatures)
        _scalar_same_owners(signatures[row - 1], signatures[row]) && continue
        push!(ranges, start:(row - 1))
        start = row
    end
    push!(ranges, start:length(signatures))
    # Object count must not become generated tuple/code size when physical
    # cohorts alternate. This bounded compiler preserves the ordinary path.
    length(ranges) <= 32 || throw(ArgumentError("too many alternating native cohorts"))
    return Tuple(_scalar_native_batch(batch, names, rows, context_strategy, initial_ids) for rows in ranges)
end

function _scalar_compile_plan(simulation, state_strategy, context_strategy, initial_ids)
    schedule = simulation.compiled.scenario_plan.application_schedule
    nodes = Any[]
    reasons = NamedTuple[]
    native_rows = native_batches = native_fields = thin_context_batches = original_context_batches = 0
    for (entry_index, entry) in enumerate(schedule.entries)
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        batches = Any[]
        if !isnothing(group)
            for batch in group.batches
                names, writes, reason = CR._region_batch_reason(simulation, batch)
                selected = nothing
                if reason === :eligible
                    try
                        selected = state_strategy === :native ?
                            _scalar_prepare_batch(batch, names, context_strategy, initial_ids) :
                            (_scalar_reference_batch(batch, names, writes, context_strategy),)
                    catch exception
                        exception isa ArgumentError || rethrow()
                        reason = :non_native_or_heterogeneous_ports
                    end
                end
                if isnothing(selected)
                    push!(batches, ScalarOrderedBatch(batch))
                else
                    append!(batches, selected)
                    native_batches += length(selected)
                    native_rows += length(batch.targets)
                    thin_context_batches += count(_scalar_has_thin_context, selected)
                    original_context_batches += count(batch -> !_scalar_has_thin_context(batch), selected)
                    state_strategy === :native && (native_fields += length(names) * length(selected))
                end
                push!(reasons, (application=batch.application.id,
                    targets=length(batch.targets), reason))
            end
        end
        push!(nodes, NativeScalarApplication(entry_index, entry.application_slot, Tuple(batches)))
    end
    return NativeScalarPlan(Tuple(nodes), schedule, simulation.runtime_revision,
        simulation.environment_bindings.environment_revision,
        (native_batches=native_batches, selected_row_memberships=native_rows,
            native_column_fields=native_fields, state_strategy,
            context_strategy, thin_context_batches, original_context_batches,
            ordered_batch_payload=:erased_ordinary_batch,
            ordered_execution_boundary=:noinline_nospecialize_original_runtime,
            newborn_membership_counting=:cached_at_lowering,
            final_backend_relowering=:deferred_until_next_use,
            reasons=Tuple(reasons), numerical_scalar_copies=false,
            rich_semantic_plan_retained=true, lifecycle_policy=:ordinary_refresh_then_relower))
end

function compile_native_scalar(simulation; state_strategy::Symbol=:native,
    context_strategy::Symbol=:thin)
    state_strategy in (:native, :references) ||
        throw(ArgumentError("state_strategy must be :native or :references"))
    context_strategy in (:thin, :original) ||
        throw(ArgumentError("context_strategy must be :thin or :original"))
    PSE._compiled_source_finalize!(simulation)
    model = PSE.runtime_model(simulation)
    state_strategy === :native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Construct native canonical storage before compilation"))
    initial_ids = Set(PSE.object_ids(model))
    return NativeScalarProgram(simulation, initial_ids,
        _scalar_compile_plan(simulation, state_strategy, context_strategy, initial_ids),
        NativeScalarCounters(), state_strategy, 0)
end

function _scalar_ensure!(program)
    simulation = program.simulation
    PSE._compiled_source_finalize!(simulation)
    if program.plan.runtime_revision != simulation.runtime_revision ||
       program.plan.environment_revision != simulation.environment_bindings.environment_revision
        program.plan = _scalar_compile_plan(simulation, program.state_strategy,
            program.plan.report.context_strategy, program.initial_ids)
        program.rebuilds += 1
    end
    return program.plan
end

@inline function _scalar_run_batch!(batch::NativeScalarBatch, program, step)
    simulation = program.simulation
    environment = PSE._model_execution_batch_environment(batch.kernel.environment_provider,
        simulation.environment_bindings, batch.application, step)
    context = batch.kernel.context
    context isa PSE.RunContext && (context.time = float(step))
    GP._column_numerical_loop!(batch.data, (batch.kernel,), (environment,),
        simulation.constants, step)
    program.counters.driver_batches += 1
    program.counters.driver_rows += batch.data.nrows
    if program.state_strategy === :native
        program.counters.native_batches += 1
        program.counters.native_rows += batch.data.nrows
        program.counters.native_fields += length(keys(batch.data.arrays)) * batch.data.nrows
        program.counters.native_newborn_rows += batch.newborn_rows
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _scalar_run_original_erased!(batch, simulation, step)
    @nospecialize batch simulation
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

@inline function _scalar_run_batch!(batch::ScalarOrderedBatch, program, step)
    _scalar_run_original_erased!(batch.batch, program.simulation, step)
    program.counters.ordered_batches += 1
    return nothing
end

@generated function _scalar_run_batches!(batches::B, program, step) where {B<:Tuple}
    return Expr(:block, [:( _scalar_run_batch!(getfield(batches, $index), program, step))
        for index in 1:fieldcount(B)]..., :(nothing))
end

@generated function _scalar_run_nodes!(nodes::N, schedule, program, step) where {N<:Tuple}
    operations = Expr[]
    for index in 1:fieldcount(N)
        push!(operations, quote
            node = getfield(nodes, $index)
            if CR._region_entry_due(schedule, node.entry, step)
                if changed
                    group = simulation.execution_plan.groups_by_application_slot[node.application_slot]
                    if !isnothing(group)
                        PSE._run_model_execution_group!(group, simulation, step, simulation.performance)
                        program.counters.lifecycle_fallback_groups += 1
                    end
                else
                    _scalar_run_batches!(node.batches, program, step)
                end
                if PSE._simulation_runtime_dirty(simulation, simulation.performance)
                    completed = GP._program_refresh_after!(simulation, schedule, completed, node.entry)
                    changed = true
                end
            end
        end)
    end
    return quote
        simulation = program.simulation
        changed = false
        completed = nothing
        $(operations...)
        nothing
    end
end

function _scalar_step!(program, plan, step)
    simulation = program.simulation
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
        plan.schedule, Int(step))
    _scalar_run_nodes!(plan.nodes, plan.schedule, program, step)
    simulation.current_step = step
    return nothing
end

function advance_native_scalar!(program; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    simulation = program.simulation
    if !isnothing(simulation.performance)
        PSE.continue!(simulation; steps)
        return simulation
    end
    for _ in 1:steps
        plan = _scalar_ensure!(program)
        _scalar_step!(program, plan, simulation.current_step + 1)
    end
    # Finalize canonical statuses, streams and ordinary semantic/runtime plans.
    # Additional backend lowering is needed only before its next execution.
    PSE._compiled_source_finalize!(simulation)
    return simulation
end

function native_scalar_report(program)
    simulation = program.simulation
    semantic_runtime_current = simulation.runtime_revision == simulation.model.runtime_revision
    plan_current = semantic_runtime_current && program.plan.runtime_revision == simulation.runtime_revision &&
        program.plan.environment_revision == simulation.environment_bindings.environment_revision
    return (; program.plan.report...,
        plan_current, semantic_runtime_current,
        plan_runtime_revision=program.plan.runtime_revision,
        runtime_revision=simulation.runtime_revision,
        model_runtime_revision=simulation.model.runtime_revision,
        plan_environment_revision=program.plan.environment_revision,
        environment_revision=simulation.environment_bindings.environment_revision,
        driver_batch_executions=program.counters.driver_batches,
        driver_row_executions=program.counters.driver_rows,
        native_batch_executions=program.counters.native_batches,
        native_row_executions=program.counters.native_rows,
        executed_native_column_fields=program.counters.native_fields,
        native_newborn_row_executions=program.counters.native_newborn_rows,
        ordered_batch_executions=program.counters.ordered_batches,
        lifecycle_fallback_groups=program.counters.lifecycle_fallback_groups,
        rebuilds=program.rebuilds,
        storage=PSE.native_storage_report(PSE.runtime_model(program.simulation)))
end

function native_scalar_column_checks()
    @testset "Canonical scalar views preserve arbitrary physical identities" begin
        values_ = Float32[1, 2, 3]
        borrowed = _scalar_native_column([Ref(values_, index) for index in (3, 1, 3)])
        @test collect(borrowed) == Float32[3, 1, 3]
        borrowed[1] = 9.0f0
        @test borrowed[3] === 9.0f0
        @test values_ == Float32[1, 2, 9]
        values_[1] = 7.0f0
        @test borrowed[2] === 7.0f0
        push!(values_, 4.0f0)
        @test collect(borrowed) == Float32[9, 7, 9]
        holes = _scalar_native_column([Ref(values_, 1), Ref(values_, 4)])
        holes[2] = 8.0f0
        @test values_[4] === 8.0f0
        @test_throws ArgumentError _scalar_native_column([Ref(1.0f0)])
        @test_throws ArgumentError _scalar_native_column([Ref(values_, 1), Ref(Float32[2], 1)])
    end
    return (passed=true, arbitrary_order=true, repeated_aliases=true,
        holes=true, appended_storage=true, scalar_copies=false)
end

"""Bounded ordinary-boundary and thin/original context semantic gate."""
function native_scalar_boundary_checks()
    reports = Any[]
    @testset "Erased ordinary boundaries retain growth and public continuation" begin
        @test fieldtype(ScalarOrderedBatch, :batch) === Any
        @test typeof(ScalarOrderedBatch((x=1,))) === typeof(ScalarOrderedBatch((y=2.0,)))
        for context_strategy in (:original, :thin)
            control = PSE.run!(GP.growth_fixture(); steps=0, outputs=:all)
            simulation = PSE.run!(GP.growth_fixture(); steps=0, outputs=:all)
            program = compile_native_scalar(simulation;
                state_strategy=:references, context_strategy)
            for _ in 1:2
                PSE.continue!(control; steps=1)
                advance_native_scalar!(program; steps=1)
                @test isequal(GP.fingerprint(simulation), GP.fingerprint(control))
            end
            PSE.continue!(control; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(control))
            report = native_scalar_report(program)
            @test report.ordered_batch_executions > 0
            @test report.driver_row_executions > 0
            context_strategy === :thin && @test report.thin_context_batches > 0
            context_strategy === :original && @test report.thin_context_batches == 0
            push!(reports, (; context_strategy, report))
        end
    end
    return (; passed=true, reports,
        qualification=:bounded_growth_publication_and_context_gate_not_compilation_measurement)
end

end # module
