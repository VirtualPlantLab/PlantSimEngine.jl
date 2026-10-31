module GrowthPlanStorageChecks

using Dates, Serialization, Test, PlantSimEngine
const PSE = PlantSimEngine

export growth_plan_storage_checks, growth_plan_storage_feature_checks,
    growth_plan_storage_downstream_checks

_checks() = getfield(Main, :GrowthInputReuseChecks)
_fixtures() = getfield(Main, :DirectPlannerFixtures)
_storage() = getfield(Main, :GrowthPlanStorage)
_enable!(model) = Base.invokelatest(
    getfield(_storage(), :enable_growth_plan_storage!), model)
_report(value) = Base.invokelatest(
    getfield(_storage(), :growth_plan_storage_report), value)
_plans(simulation) = Dict(application.id => application.plan
    for application in simulation.compiled.applications)

function _heap_plans(simulation; readonly=false)
    Heap = getfield(_storage(), :HeapApplicationPlan)
    count = 0
    for application in simulation.compiled.applications
        plan = application.plan
        @test plan isa Heap
        @test ismutabletype(typeof(plan))
        ordinary_type = Core.apply_type(PSE.CompiledApplicationPlan, typeof(plan).parameters...)
        @test fieldnames(typeof(plan)) == fieldnames(ordinary_type)
        @test fieldtypes(typeof(plan)) == fieldtypes(ordinary_type)
        @test all(name -> isconst(typeof(plan), name), fieldnames(typeof(plan)))
        @test simulation.compiled.scenario_plan.applications_by_id[application.id] === plan
        @test any(candidate -> candidate === plan, simulation.compiled.scenario_plan.applications)
        if readonly
            for name in fieldnames(typeof(plan))
                error = try
                    setfield!(plan, name, getfield(plan, name))
                    nothing
                catch exception
                    exception
                end
                @test error !== nothing
                @test error !== nothing && occursin("const", sprint(showerror, error))
            end
        end
        count += 1
    end
    @test count > 0
    return count
end

function _retained_plans(simulation, previous)
    current = _plans(simulation)
    @test keys(current) == keys(previous)
    @test all(id -> current[id] === previous[id], keys(previous))
    return current
end

function _storage_evidence(simulation; report=_report)
    actual_heap_plans = _heap_plans(simulation)
    observed = Base.invokelatest(report, simulation)
    @test observed.enabled
    @test observed.heap_plans_constructed > 0
    @test observed.current_applications == length(simulation.compiled.applications)
    @test observed.current_heap_plans == actual_heap_plans
    @test observed.plan_fields_read_only
    return (; actual_heap_plans, report=observed,
        interpretation=:constructed_heap_metadata_objects_not_driver_or_binding_reuse)
end

function _checkpoint(simulation)
    buffer = IOBuffer()
    serialize(buffer, simulation)
    seekstart(buffer)
    return deserialize(buffer)
end

"""Paired Float32 growth plus read-only metadata, identity, and checkpoint gates.

The opt-in arm keeps ordinary reference storage and ordinary execution. It
reuses the existing generic fixture and parity/live-binding oracles; no input
partition policy is enabled and no partition/driver counters are synthesized.
"""
function growth_plan_storage_checks(; enable! = _enable!, report=_report, outputs=:all)
    C, F = _checks(), _fixtures()
    reports = Any[]
    @testset "Heap application metadata preserves ordinary growth and read-only plans" begin
        for nobjects in (1, 3)
            reference = PSE.run!(C._generic_fixture(nobjects); steps=0, outputs)
            candidate = C._prepare(C._generic_fixture(nobjects); enable!, outputs)
            @test all(application -> application.plan isa PSE.CompiledApplicationPlan,
                reference.compiled.applications)
            _heap_plans(candidate; readonly=true)
            retained = _plans(candidate)
            previous = C._initial_pair(reference, candidate)
            source_cells = map(simulation -> PSE.refvalue(
                PSE.model_status(simulation.model, 1), :signal), (reference, candidate))
            PSE.step!(reference); PSE.step!(candidate)
            previous = C._pair_state(reference, candidate, previous)
            source_cells[1][] = source_cells[2][] = 10.25f0
            for simulation in (reference, candidate)
                PSE.register_object!(simulation.model, C._unit(nobjects+1))
                PSE.register_object!(simulation.model, PSE.Object(:new; kind=:growth_input_gatherer))
                PSE.register_object!(simulation.model, C._unit(nobjects+2; parent=:new))
                PSE.step!(simulation)
                C._live_bindings(simulation)
            end
            retained = _retained_plans(candidate, retained)
            previous = C._pair_state(reference, candidate, previous)
            retired_cells = map(simulation -> PSE.refvalue(
                PSE.model_status(simulation.model, 2), :signal), (reference, candidate))
            retired_values = map(cell -> cell[], retired_cells)
            optional_cells = map(simulation -> PSE.refvalue(
                PSE.model_status(simulation.model, :left), :optional), (reference, candidate))
            for (index, simulation) in pairs((reference, candidate))
                PSE.reparent_object!(simulation.model, nobjects+1, :right)
                PSE.remove_object!(simulation.model, 2)
                PSE.step!(simulation)
                C._live_bindings(simulation)
                @test PSE.refvalue(PSE.model_status(simulation.model, :left), :optional) === optional_cells[index]
                @test retired_cells[index][] === retired_values[index]
            end
            retained = _retained_plans(candidate, retained)
            previous = C._pair_state(reference, candidate, previous)
            for (index, simulation) in pairs((reference, candidate))
                PSE.register_object!(simulation.model, C._unit(2; value=30.0f0))
                PSE.step!(simulation)
                C._live_bindings(simulation)
                @test PSE.refvalue(PSE.model_status(simulation.model, 2), :signal) !== retired_cells[index]
                @test retired_cells[index][] === retired_values[index]
                @test PSE.refvalue(PSE.model_status(simulation.model, 1), :signal) === source_cells[index]
            end
            retained = _retained_plans(candidate, retained)
            previous = C._pair_state(reference, candidate, previous)

            copied, restored = deepcopy(candidate), _checkpoint(candidate)
            C._initial_pair(candidate, copied)
            C._initial_pair(candidate, restored)
            copied_plans, restored_plans = _plans(copied), _plans(restored)
            _heap_plans(copied); _heap_plans(restored)
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            C._pair_state(reference, candidate, previous)
            for branch in (copied, restored)
                PSE.continue!(branch; steps=1)
                @test isequal(F.snapshot(branch, :generic), F.snapshot(candidate, :generic))
                C._live_bindings(branch)
            end
            _retained_plans(candidate, retained)
            _retained_plans(copied, copied_plans)
            _retained_plans(restored, restored_plans)
            push!(reports, (; nobjects, evidence=_storage_evidence(candidate; report)))
        end
    end
    return (; passed=true, outputs, reports,
        oracle=:ordinary_exact_history_live_refs_readonly_metadata_and_checkpoint_continuation)
end

"""One trusted initializer/temporal or distributed fallback fixture."""
function growth_plan_storage_feature_checks(case::Symbol=:initializer;
    enable! = _enable!, report=_report, outputs=:all)
    C = _checks()
    N = getfield(Main, :NewbornPreparationChecks)
    if case in (:initializer, :mixed_cadence)
        cadence = case === :mixed_cadence ? Hour(2) : Hour(1)
        left, right = N.preparation_fixture(; source_every=cadence),
            N.preparation_fixture(; source_every=cadence)
        left_model, right_model = left.model, right.model
        steps = case === :mixed_cadence ? 4 : 3
    elseif case in (:distributed, :distributed_from_status)
        D = getfield(Main, :NewbornDistributedChecks)
        mode = case === :distributed ? :direct : :from_status
        left_model, right_model = D.distributed_fixture(mode), D.distributed_fixture(mode)
        steps = 3
    else
        throw(ArgumentError("Choose :initializer, :mixed_cadence, :distributed or :distributed_from_status"))
    end
    reference = PSE.run!(left_model; steps=0, outputs)
    candidate = C._prepare(right_model; enable!, outputs)
    @testset "Heap metadata preserves existing targeted and distributed features" begin
        previous = C._initial_pair(reference, candidate)
        retained = _plans(candidate)
        _heap_plans(candidate)
        for _ in 1:steps
            PSE.step!(reference); PSE.step!(candidate)
            previous = C._pair_state(reference, candidate, previous)
            @test isequal(N._snapshot(candidate), N._snapshot(reference))
            C._live_bindings(candidate)
            retained = _retained_plans(candidate, retained)
        end
    end
    return (; passed=true, case, outputs, evidence=_storage_evidence(candidate; report),
        oracle=:ordinary_exact_targeted_initializer_temporal_distributed_and_history_behavior)
end

"""Independent original PB/XP; no scientific method changes or wrappers."""
function growth_plan_storage_downstream_checks(kind::Symbol=:pb;
    enable! = _enable!, report=_report, steps=2, nobjects=2, outputs=:all)
    kind in (:pb, :xp) || throw(ArgumentError("Choose :pb or :xp"))
    C, F = _checks(), _fixtures()
    H = getfield(Main, :DirectPlannerMeasurements)
    config = H.construct_config(kind; steps, nobjects, outputs)
    left, right = F.construct_fixture(kind, config), F.construct_fixture(kind, config)
    reference = PSE.run!(left.model; steps=0, outputs)
    candidate = C._prepare(right.model; enable!, outputs)
    @testset "Heap metadata preserves independent original downstream science" begin
        previous = C._initial_pair(reference, candidate; kind)
        retained = _plans(candidate)
        _heap_plans(candidate)
        for _ in 1:steps
            PSE.step!(reference); PSE.step!(candidate)
            previous = C._pair_state(reference, candidate, previous; kind)
            C._live_bindings(candidate)
            retained = _retained_plans(candidate, retained)
        end
        CR = getfield(Main, :CompiledRegionsExperiment)
        @test CR.downstream_work_report(candidate, right.initial_ids) ==
            CR.downstream_work_report(reference, left.initial_ids)
    end
    return (; passed=true, kind, steps, outputs, evidence=_storage_evidence(candidate; report),
        oracle=:independent_original_exact_state_history_rng_and_identity_transitions)
end

end # module
