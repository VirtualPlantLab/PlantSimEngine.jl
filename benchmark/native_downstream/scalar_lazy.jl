module NativeScalarLazy
using Test, PlantSimEngine
const PSE = PlantSimEngine
const Scalar = Main.NativeScalarDriver
const Reuse = Main.NativeScalarReuse
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
const XP = Main.NativeXPDriver
mutable struct LazyScalarProgram{B}
    base::B
    cache::Dict{Int,Reuse.CachedScalarApplication}
    pure_addition_only::Bool
    transition_observed::Bool
    runtime_revision::Int
    environment_revision::Int
    observed_runtime_revision::Int
    observed_environment_revision::Int
    prepared_applications::Int
    reused_applications::Int
    reused_numeric_applications::Int
    full_invalidations::Int
end
function compile_lazy_scalar(simulation; context_strategy::Symbol=:thin)
    context_strategy in (:thin, :original) || throw(ArgumentError("invalid context strategy"))
    PSE._compiled_source_finalize!(simulation)
    simulation.model.status_storage isa PSE.NativeColumnStorage ||
        throw(ArgumentError("lazy native execution requires canonical native construction"))
    schedule = simulation.compiled.scenario_plan.application_schedule
    report = (context_strategy=context_strategy, state_strategy=:native)
    plan = Scalar.NativeScalarPlan((), schedule, simulation.runtime_revision,
        simulation.environment_bindings.environment_revision, report)
    base = Scalar.NativeScalarProgram(simulation, Set(PSE.object_ids(simulation.model)),
        plan, Scalar.NativeScalarCounters(), :native, 0)
    return LazyScalarProgram(base, Dict{Int,Reuse.CachedScalarApplication}(), true, false,
        simulation.runtime_revision, simulation.environment_bindings.environment_revision,
        simulation.runtime_revision, simulation.environment_bindings.environment_revision, 0, 0, 0, 0)
end
function _observe!(program)
    sim = program.base.simulation
    program.pure_addition_only &= sim.runtime_revision == program.observed_runtime_revision &&
        sim.environment_bindings.environment_revision == program.observed_environment_revision
    Reuse._observe_pending_change!(program)
end
function _observed_refresh!(program)
    sim = program.base.simulation
    program.observed_runtime_revision = sim.runtime_revision
    program.observed_environment_revision = sim.environment_bindings.environment_revision
end
function _align_epoch!(program)
    simulation = program.base.simulation
    _observe!(program)
    PSE._compiled_source_finalize!(simulation)
    _observed_refresh!(program)
    if program.runtime_revision != simulation.runtime_revision ||
       program.environment_revision != simulation.environment_bindings.environment_revision
        if !(program.pure_addition_only && program.transition_observed)
            empty!(program.cache)
            program.full_invalidations += 1
        end
        program.runtime_revision = simulation.runtime_revision
        program.environment_revision = simulation.environment_bindings.environment_revision
        program.pure_addition_only = true
        program.transition_observed = false
    end
    return nothing
end
function _application!(program, entry, group)
    key = entry.application_slot
    cached = get(program.cache, key, nothing)
    if !isnothing(cached) && Reuse._cache_matches(cached, entry, group)
        program.reused_applications += 1
        program.reused_numeric_applications += cached.metrics.native_batches > 0
        return cached
    end
    record = Reuse._prepare_entry(program.base, entry, group)
    program.cache[key] = record
    program.prepared_applications += 1
    return record
end
function _lazy_step!(program, step)
    base = program.base
    simulation = base.simulation
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    schedule = simulation.compiled.scenario_plan.application_schedule
    due = PSE._due_application_schedule_entries!(simulation.execution_plan.schedule, schedule, Int(step))
    changed = false
    completed = nothing
    for index in due
        entry = schedule.entries[index]
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        isnothing(group) && continue
        if changed
            PSE._run_model_execution_group!(group, simulation, step, simulation.performance)
            base.counters.lifecycle_fallback_groups += 1
        else
            record = _application!(program, entry, group)
            # One dynamic dispatch per cached batch; numerical inner loops
            # retain the unchanged concrete Scalar batch/kernel types.
            for batch in record.lowered_batches
                Scalar._scalar_run_batch!(batch, base, step)
            end
        end
        if PSE._simulation_runtime_dirty(simulation, simulation.performance)
            _observe!(program)
            completed = GP._program_refresh_after!(simulation, schedule, completed, index)
            _observed_refresh!(program)
            changed = true
        end
    end
    simulation.current_step = step
    return nothing
end
function advance_lazy_scalar!(program; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    simulation = program.base.simulation
    if !isnothing(simulation.performance)
        program.pure_addition_only = false
        PSE.continue!(simulation; steps)
        return simulation
    end
    for _ in 1:steps
        _align_epoch!(program)
        _lazy_step!(program, simulation.current_step + 1)
    end
    _observe!(program)
    PSE._compiled_source_finalize!(simulation)
    _observed_refresh!(program)
    return simulation
end
function lazy_scalar_report(program)
    counters = program.base.counters
    simulation = program.base.simulation
    return (strategy=:lazy_executed_application_native,
        native_row_executions=counters.native_rows, driver_row_executions=counters.driver_rows,
        native_newborn_row_executions=counters.native_newborn_rows,
        executed_native_column_fields=counters.native_fields,
        ordered_batch_executions=counters.ordered_batches,
        lifecycle_fallback_groups=counters.lifecycle_fallback_groups,
        prepared_applications=program.prepared_applications,
        reused_applications=program.reused_applications,
        reused_numeric_applications=program.reused_numeric_applications,
        full_invalidations=program.full_invalidations, cached_applications=length(program.cache),
        semantic_runtime_current=simulation.runtime_revision == simulation.model.runtime_revision,
        cache_epoch_current=program.runtime_revision == simulation.runtime_revision &&
            program.environment_revision == simulation.environment_bindings.environment_revision,
        cache_guards_rechecked_on_access=true, numerical_scalar_copies=false,
        initial_full_lowering=false, outer_scheduler=:ordinary_due_entry_list,
        context_strategy=program.base.plan.report.context_strategy,
        storage=PSE.native_storage_report(simulation.model))
end
function lazy_scalar_preflight(; xp_steps::Int=4)
    summaries = Any[]
    @testset "Lazy executed-application native compiler" begin
        control = PSE.run!(Reuse._probe_fixture(native=false); steps=0, outputs=:all)
        simulation = PSE.run!(Reuse._probe_fixture(native=true); steps=0, outputs=:all)
        program = compile_lazy_scalar(simulation)
        advance_and_check() = begin
            PSE.continue!(control; steps=1)
            advance_lazy_scalar!(program; steps=1)
            @test isequal(CR.downstream_fingerprint(control), CR.downstream_fingerprint(simulation))
        end
        advance_and_check()
        for sim in (control, simulation)
            PSE.register_object!(sim.model, PSE.Object(5; kind=:unit, status=(x=0.0f0,)))
        end
        advance_and_check()
        @test program.reused_numeric_applications > 0
        mutations = (
            sim -> PSE.remove_object!(sim.model, 4),
            sim -> Reuse._replace_probe_model!(sim.model),
            sim -> begin
                PSE._replace_model_object_status!(sim.model, PSE.ObjectId(1), PSE.Status(x=100.0f0))
                PSE._mark_bindings_dirty!(sim.model, (PSE.ObjectId(1),); kind=:structural)
            end,
            sim -> PSE.move_object!(sim.model, 2, (position=(1.0f0, 0.0f0, 0.0f0),)),
            sim -> begin
                PSE.register_object!(sim.model, PSE.Object(6; kind=:unit, status=(x=0.0f0,)))
                PSE.mark_environment_binding_dirty!(sim.model, 2)
            end,
            sim -> begin
                PSE.remove_object!(sim.model, 5)
                PSE.register_object!(sim.model, PSE.Object(5; kind=:unit, status=(x=50.0f0,)))
            end,
        )
        for mutate in mutations
            mutate(control); mutate(simulation)
            before = program.full_invalidations
            advance_and_check()
            @test program.full_invalidations > before
        end
        PSE.continue!(control; steps=1); PSE.continue!(simulation; steps=1)
        @test isequal(CR.downstream_fingerprint(control), CR.downstream_fingerprint(simulation))
        push!(summaries, (case=:mutations, invalidations=program.full_invalidations,
            reused_numeric=program.reused_numeric_applications))
        control = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=false); steps=0, outputs=:all)
        simulation = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=true); steps=0, outputs=:all)
        rebuilt = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, native=true); steps=0, outputs=:all)
        program = compile_lazy_scalar(simulation)
        original = Scalar.compile_native_scalar(rebuilt)
        for _ in 1:xp_steps
            PSE.continue!(control; steps=1)
            Scalar.advance_native_scalar!(original; steps=1)
            advance_lazy_scalar!(program; steps=1)
            expected = XP.xp_portable_snapshot(control)
            @test isequal(XP.xp_portable_snapshot(simulation), expected)
            @test isequal(XP.xp_portable_snapshot(rebuilt), expected)
        end
        report = lazy_scalar_report(program)
        @test report.native_row_executions == original.counters.native_rows > 0
        @test report.native_newborn_row_executions == original.counters.native_newborn_rows > 0
        @test report.reused_numeric_applications > 0
        push!(summaries, (case=:real_xpalm, native_rows=report.native_row_executions,
            newborn_rows=report.native_newborn_row_executions,
            prepared=report.prepared_applications, reused_numeric=report.reused_numeric_applications,
            cached=report.cached_applications, runtime_current=report.semantic_runtime_current))
    end
    return (passed=true, cases=length(summaries), summaries)
end
function register_lazy_xp_case!(name::Symbol=:xp_lazy; steps::Int=4, outputs=:none, replace=false)
    M = Main.NativeDownstreamMeasurements
    weather = CR._xpalm_fixture_weather(steps)
    variants = (M.VariantSpec(:reference_executor), M.VariantSpec(:native_executor; native=true),
        M.VariantSpec(:native_rebuild; native=true, driver=true),
        M.VariantSpec(:native_reuse; native=true, driver=true), M.VariantSpec(:native_lazy; native=true, driver=true))
    return M.register_case!(name; config=(; steps, outputs), variants, replace, packages=(PSE, XP.XPalm),
        construct=(config, variant) -> begin
            model = XP.xpalm_native_fixture(; steps=config.steps, weather, native=variant.needs_native)
            (model=model, initial_ids=collect(PSE.object_ids(model)))
        end,
        prepare=(fixture, config, variant) -> PSE.run!(fixture.model; steps=0, outputs=config.outputs),
        lower=(sim, fixture, config, variant) -> !variant.needs_driver ? nothing :
            variant.name === :native_lazy ? compile_lazy_scalar(sim) :
            variant.name === :native_reuse ? Reuse.compile_reusing_scalar(sim) : Scalar.compile_native_scalar(sim),
        execute! = (sim, program, fixture, config, variant) -> isnothing(program) ? PSE.continue!(sim; steps=config.steps) :
            program isa LazyScalarProgram ? advance_lazy_scalar!(program; steps=config.steps) :
            program isa Reuse.ReusingScalarProgram ? Reuse.advance_reusing_scalar!(program; steps=config.steps) :
            Scalar.advance_native_scalar!(program; steps=config.steps),
        fingerprint=(sim, fixture, config) -> XP.xp_portable_snapshot(sim),
        coverage=(sim, program, fixture, config, variant) -> begin
            storage = PSE.native_storage_report(fixture.model)
            isnothing(program) && return (native_fields=variant.needs_native ? storage.active_native_fields : 0,
                driver_units=0, native_driver_units=0, storage)
            report = program isa LazyScalarProgram ? lazy_scalar_report(program) :
                program isa Reuse.ReusingScalarProgram ? Reuse.reuse_scalar_report(program) : Scalar.native_scalar_report(program)
            (native_fields=report.executed_native_column_fields, driver_units=report.driver_row_executions,
                native_driver_units=report.native_row_executions, storage, report)
        end,
        work=(sim, fixture, config) -> CR.downstream_work_report(sim, fixture.initial_ids))
end
end
