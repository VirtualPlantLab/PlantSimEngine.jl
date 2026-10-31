module NativeScalarReuse

using Dates
using Test
using PlantSimEngine

const PSE = PlantSimEngine
const Scalar = Main.NativeScalarDriver
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
const XP = Main.NativeXPDriver

struct CachedScalarApplication
    entry::PSE.CompiledApplicationScheduleEntry
    source_group::Any
    source_batches::Vector{Any}
    target_counts::Vector{Int}
    providers::Vector{Any}
    lowered_batches::Any
    cacheable::Bool
    metrics::Any
end

mutable struct ReusingScalarProgram{B}
    base::B
    cache::Vector{CachedScalarApplication}
    pure_addition_only::Bool
    transition_observed::Bool
    reused_groups::Int
    reused_numeric_groups::Int
    rebuilt_groups::Int
    full_invalidations::Int
end

_provider(batch) = hasproperty(batch, :environment_provider) ? batch.environment_provider : nothing
_target_count(batch) = hasproperty(batch, :targets) ? length(batch.targets) : -1

function _local_ports_only(group)
    isnothing(group) && return true
    for batch in group.batches
        batch isa PSE.CompiledExecutionBatch || continue
        for target in batch.targets
            CR.region_effects(typeof(target.model)) === :local_ports || return false
        end
    end
    return true
end

function _metrics(lowered, reasons)
    native = [batch for batch in lowered if batch isa Scalar.NativeScalarBatch]
    return (native_batches=length(native),
        selected_row_memberships=sum(batch.data.nrows for batch in native; init=0),
        native_column_fields=sum(length(keys(batch.data.arrays)) for batch in native; init=0),
        thin_context_batches=count(Scalar._scalar_has_thin_context, native),
        original_context_batches=count(batch -> !Scalar._scalar_has_thin_context(batch), native),
        reasons=Tuple(reasons))
end

function _cache_entry(entry, group, lowered, reasons)
    batches = isnothing(group) ? Any[] : Any[group.batches...]
    numeric = any(batch -> batch isa Scalar.NativeScalarBatch, lowered)
    return CachedScalarApplication(entry, group, batches,
        [_target_count(batch) for batch in batches],
        Any[_provider(batch) for batch in batches], lowered,
        !numeric || _local_ports_only(group), _metrics(lowered, reasons))
end

function _cache_matches(cached, entry, group)
    cached.cacheable && cached.entry === entry && cached.source_group === group || return false
    isnothing(group) && return true
    length(cached.source_batches) == length(group.batches) || return false
    for index in eachindex(cached.source_batches)
        batch = group.batches[index]
        cached.source_batches[index] === batch || return false
        cached.target_counts[index] == _target_count(batch) || return false
        cached.providers[index] === _provider(batch) || return false
    end
    return true
end

function _prepare_entry(base, entry, group)
    lowered = Any[]
    reasons = NamedTuple[]
    if !isnothing(group)
        for batch in group.batches
            names, writes, reason = CR._region_batch_reason(base.simulation, batch)
            selected = nothing
            if reason === :eligible
                try
                    selected = Scalar._scalar_prepare_batch(batch, names,
                        base.plan.report.context_strategy, base.initial_ids)
                catch exception
                    exception isa ArgumentError || rethrow()
                    reason = :non_native_or_heterogeneous_ports
                end
            end
            isnothing(selected) ? push!(lowered, Scalar.ScalarOrderedBatch(batch)) :
                append!(lowered, selected)
            push!(reasons, (application=batch.application.id,
                targets=_target_count(batch), reason))
        end
    end
    return _cache_entry(entry, group, Tuple(lowered), reasons)
end

function compile_reusing_scalar(simulation; context_strategy::Symbol=:thin)
    base = Scalar.compile_native_scalar(simulation;
        state_strategy=:native, context_strategy)
    cache = CachedScalarApplication[]
    for (index, entry) in enumerate(base.plan.schedule.entries)
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        reasons = filter(row -> row.application == entry.application_id, base.plan.report.reasons)
        push!(cache, _cache_entry(entry, group, base.plan.nodes[index].batches, reasons))
    end
    return ReusingScalarProgram(base, cache, true, false, 0, 0, 0, 0)
end

function _pure_addition(delta)
    delta.structural_kind === :addition && !delta.full_environment &&
        isempty(delta.removed) && isempty(delta.reparented) && isempty(delta.moved) || return false
    added_ids = Set(snapshot.id for snapshot in delta.added)
    isempty(added_ids) && return false
    # A coalesced explicit invalidation of an existing object's handle is
    # stronger than addition, even without a recorded movement event.
    return all(id -> id in added_ids, delta.environment_dirty_ids)
end

function _observe_pending_change!(program)
    simulation = program.base.simulation
    if PSE._simulation_runtime_dirty(simulation, simulation.performance)
        program.transition_observed = true
        program.pure_addition_only &= _pure_addition(PSE.lifecycle_delta(simulation.model))
    end
    return nothing
end

function _ensure_reusing_plan!(program)
    base = program.base
    simulation = base.simulation
    _observe_pending_change!(program)
    PSE._compiled_source_finalize!(simulation)
    old = base.plan
    if old.runtime_revision == simulation.runtime_revision &&
       old.environment_revision == simulation.environment_bindings.environment_revision
        return old
    end
    schedule = simulation.compiled.scenario_plan.application_schedule
    updated = CachedScalarApplication[]
    nodes = Any[]
    reused = reused_numeric = rebuilt = 0
    may_reuse = program.pure_addition_only && program.transition_observed
    may_reuse || (program.full_invalidations += 1)
    for (index, entry) in enumerate(schedule.entries)
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        cached = index <= length(program.cache) ? program.cache[index] : nothing
        if may_reuse && !isnothing(cached) && _cache_matches(cached, entry, group)
            # PSE reuses an unchanged group itself. Its ordinary delta path
            # constructs a new working_group for replacements/removals;
            # transactional pure addition may mutate the old target vectors,
            # which is why captured numeric counts are checked above.
            record = cached
            if !isnothing(group)
                reused += 1
                reused_numeric += record.metrics.native_batches > 0
            end
        else
            record = _prepare_entry(base, entry, group)
            rebuilt += !isnothing(group)
        end
        push!(updated, record)
        push!(nodes, Scalar.NativeScalarApplication(index, entry.application_slot, record.lowered_batches))
    end
    total(field) = sum(getproperty(record.metrics, field) for record in updated; init=0)
    reasons = Tuple(row for record in updated for row in record.metrics.reasons)
    report = merge(old.report, (native_batches=total(:native_batches),
        selected_row_memberships=total(:selected_row_memberships),
        native_column_fields=total(:native_column_fields),
        thin_context_batches=total(:thin_context_batches),
        original_context_batches=total(:original_context_batches), reasons,
        lifecycle_policy=:ordinary_refresh_then_reuse_unchanged_native_groups))
    base.plan = Scalar.NativeScalarPlan(Tuple(nodes), schedule, simulation.runtime_revision,
        simulation.environment_bindings.environment_revision, report)
    base.rebuilds += 1
    program.cache = updated
    program.pure_addition_only = true
    program.transition_observed = false
    program.reused_groups += reused
    program.reused_numeric_groups += reused_numeric
    program.rebuilt_groups += rebuilt
    return base.plan
end

@generated function _run_reusing_nodes!(nodes::N, schedule, program, step) where {N<:Tuple}
    operations = Expr[]
    for index in 1:fieldcount(N)
        push!(operations, quote
            node = getfield(nodes, $index)
            if CR._region_entry_due(schedule, node.entry, step)
                if changed
                    group = simulation.execution_plan.groups_by_application_slot[node.application_slot]
                    if !isnothing(group)
                        PSE._run_model_execution_group!(group, simulation, step, simulation.performance)
                        base.counters.lifecycle_fallback_groups += 1
                    end
                else
                    Scalar._scalar_run_batches!(node.batches, base, step)
                end
                if PSE._simulation_runtime_dirty(simulation, simulation.performance)
                    _observe_pending_change!(program)
                    completed = GP._program_refresh_after!(simulation, schedule, completed, node.entry)
                    changed = true
                end
            end
        end)
    end
    return quote
        base = program.base
        simulation = base.simulation
        changed = false
        completed = nothing
        $(operations...)
        nothing
    end
end

function _step_reusing!(program, plan, step)
    simulation = program.base.simulation
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
        plan.schedule, Int(step))
    _run_reusing_nodes!(plan.nodes, plan.schedule, program, step)
    simulation.current_step = step
    return nothing
end

function advance_reusing_scalar!(program; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    simulation = program.base.simulation
    if !isnothing(simulation.performance)
        program.pure_addition_only = false
        PSE.continue!(simulation; steps)
        return simulation
    end
    for _ in 1:steps
        plan = _ensure_reusing_plan!(program)
        _step_reusing!(program, plan, simulation.current_step + 1)
    end
    _observe_pending_change!(program)
    PSE._compiled_source_finalize!(simulation)
    return simulation
end

reuse_scalar_report(program) = (; Scalar.native_scalar_report(program.base)...,
    incremental_reuse=true, reused_groups=program.reused_groups,
    reused_numeric_groups=program.reused_numeric_groups,
    rebuilt_groups=program.rebuilt_groups, full_invalidations=program.full_invalidations,
    cache_entries=length(program.cache), reuse_capability=:local_ports,
    reuse_proof=:same_semantic_group_batches_counts_provider_and_cadence,
    pending_pure_addition_only=program.pure_addition_only)

PSE.@process "native_reuse_probe" verbose=false
struct ReuseProbe{T} <: AbstractNative_Reuse_ProbeModel
    increment::T
end
PSE.inputs_(::ReuseProbe) = NamedTuple()
PSE.outputs_(model::ReuseProbe) = (x=zero(model.increment),)
PSE.run!(model::ReuseProbe, status, environment, constants, context) =
    (status.x += model.increment; nothing)
CR.region_effects(::Type{<:ReuseProbe}) = :local_ports

function _probe_fixture(; native)
    objects = [PSE.Object(index; kind=:unit, status=(x=0.0f0,)) for index in 1:4]
    push!(objects, PSE.Object(:echo))
    return PSE.CompositeModel(objects...;
        status_storage=native ? PSE.NativeColumnStorage() : nothing,
        environment=(duration=Hour(1),), applications=(
            PSE.ModelSpec(ReuseProbe(1.0f0); name=:produce,
                on=PSE.Many(kind=:unit), every=Hour(1)),
            PSE.ModelSpec(CR.NativeColumnEcho{Float32}(); name=:echo,
                on=PSE.One(id=:echo), every=Hour(1), inputs=(
                    supply=PSE.One(id=1, within=PSE.SceneScope(), application=:produce, var=:x),
                )),
        ))
end

function _replace_probe_model!(model)
    # Explicit compiler-test mutation: public ObjectInstance override behavior
    # is covered by storage_features.jl; here invalidate a changed ModelSpec.
    model.applications[1] = PSE.ModelSpec(ReuseProbe(2.0f0); name=:produce,
        on=PSE.Many(kind=:unit), every=Hour(1))
    PSE._mark_bindings_dirty!(model)
    return nothing
end

function native_reuse_preflight(; xp_steps::Int=4)
    summaries = Any[]
    @testset "Incremental native groups reuse only unchanged semantic owners" begin
        control = PSE.run!(_probe_fixture(native=false); steps=0, outputs=:all)
        simulation = PSE.run!(_probe_fixture(native=true); steps=0, outputs=:all)
        program = compile_reusing_scalar(simulation)
        function advance_and_check()
            PSE.continue!(control; steps=1)
            advance_reusing_scalar!(program; steps=1)
            @test isequal(CR.downstream_fingerprint(control), CR.downstream_fingerprint(simulation))
        end
        advance_and_check()
        for sim in (control, simulation)
            PSE.register_object!(sim.model, PSE.Object(5; kind=:unit, status=(x=0.0f0,)))
        end
        advance_and_check()
        @test program.reused_numeric_groups > 0
        for sim in (control, simulation)
            PSE.register_object!(sim.model, PSE.Object(6; kind=:unit, status=(x=0.0f0,)))
            PSE.mark_environment_binding_dirty!(sim.model, 2)
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        for sim in (control, simulation)
            PSE.remove_object!(sim.model, 4)
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        for sim in (control, simulation)
            _replace_probe_model!(sim.model)
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        for sim in (control, simulation)
            PSE._replace_model_object_status!(sim.model, PSE.ObjectId(1), PSE.Status(x=100.0f0))
            PSE._mark_bindings_dirty!(sim.model, (PSE.ObjectId(1),); kind=:structural)
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        @test PSE.final_state(simulation, :echo).observed === 102.0f0
        for sim in (control, simulation)
            PSE.move_object!(sim.model, 2, (position=(1.0f0, 0.0f0, 0.0f0),))
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        # Same IDs/count after an explicit remove/add cannot pass a pure-addition proof.
        for sim in (control, simulation)
            PSE.remove_object!(sim.model, 5)
            PSE.register_object!(sim.model, PSE.Object(5; kind=:unit, status=(x=50.0f0,)))
        end
        before = program.full_invalidations
        advance_and_check()
        @test program.full_invalidations > before
        PSE.continue!(control; steps=1)
        PSE.continue!(simulation; steps=1)
        @test isequal(CR.downstream_fingerprint(control), CR.downstream_fingerprint(simulation))
        push!(summaries, (case=:public_mutations, reused_groups=program.reused_groups,
            rebuilt_groups=program.rebuilt_groups, full_invalidations=program.full_invalidations))

        control = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=false); steps=0, outputs=:all)
        simulation = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=true); steps=0, outputs=:all)
        rebuilt = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=true); steps=0, outputs=:all)
        program = compile_reusing_scalar(simulation)
        original = Scalar.compile_native_scalar(rebuilt)
        for _ in 1:xp_steps
            PSE.continue!(control; steps=1)
            Scalar.advance_native_scalar!(original; steps=1)
            advance_reusing_scalar!(program; steps=1)
            expected = XP.xp_portable_snapshot(control)
            @test isequal(XP.xp_portable_snapshot(simulation), expected)
            @test isequal(XP.xp_portable_snapshot(rebuilt), expected)
        end
        report = reuse_scalar_report(program)
        @test report.native_newborn_row_executions > 0
        @test report.reused_numeric_groups > 0
        push!(summaries, (case=:real_xpalm, reused_groups=report.reused_groups,
            reused_numeric_groups=report.reused_numeric_groups,
            rebuilt_groups=report.rebuilt_groups, full_invalidations=report.full_invalidations,
            native_rows=report.native_row_executions,
            newborn_rows=report.native_newborn_row_executions,
            runtime_current=report.semantic_runtime_current))
    end
    return (passed=true, cases=length(summaries), summaries)
end

function register_reuse_xp_case!(name::Symbol=:xp_reuse_small; steps::Int=4,
    outputs=:none, emission_speed=0.2, seed::Int=1, replace=false)
    measurements = Main.NativeDownstreamMeasurements
    weather = CR._xpalm_fixture_weather(steps)
    variants = (measurements.VariantSpec(:reference_executor),
        measurements.VariantSpec(:native_executor; native=true),
        measurements.VariantSpec(:native_driver_rebuild; native=true, driver=true),
        measurements.VariantSpec(:native_driver_reuse; native=true, driver=true))
    config = (; steps, outputs, emission_speed, seed)
    return measurements.register_case!(name; config, variants, replace, packages=(PSE, XP.XPalm),
        construct=(config, variant) -> begin
            model = XP.xpalm_native_fixture(; steps=config.steps, weather,
                emission_speed=config.emission_speed, seed=config.seed, native=variant.needs_native)
            (model=model, initial_ids=collect(PSE.object_ids(model)))
        end,
        prepare=(fixture, config, variant) -> PSE.run!(fixture.model; steps=0, outputs=config.outputs),
        lower=(simulation, fixture, config, variant) -> !variant.needs_driver ? nothing :
            variant.name === :native_driver_reuse ? compile_reusing_scalar(simulation) :
            Scalar.compile_native_scalar(simulation),
        execute! = (simulation, program, fixture, config, variant) -> isnothing(program) ?
            PSE.continue!(simulation; steps=config.steps) : program isa ReusingScalarProgram ?
            advance_reusing_scalar!(program; steps=config.steps) :
            Scalar.advance_native_scalar!(program; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> XP.xp_portable_snapshot(simulation),
        coverage=(simulation, program, fixture, config, variant) -> begin
            storage = PSE.native_storage_report(fixture.model)
            isnothing(program) && return (native_fields=variant.needs_native ? storage.active_native_fields : 0,
                driver_units=0, native_driver_units=0, storage)
            report = program isa ReusingScalarProgram ? reuse_scalar_report(program) :
                Scalar.native_scalar_report(program)
            return (native_fields=report.executed_native_column_fields,
                driver_units=report.driver_row_executions, native_driver_units=report.native_row_executions,
                storage, report)
        end,
        work=(simulation, fixture, config) -> CR.downstream_work_report(simulation, fixture.initial_ids))
end

end # module
