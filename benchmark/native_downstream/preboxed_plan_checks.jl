module PreboxedPlanChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
export preboxed_plan_checks, preboxed_plan_partition_checks
_C() = getfield(Main, :GrowthInputReuseChecks)
_F() = getfield(Main, :DirectPlannerFixtures)
_S() = getfield(Main, :GrowthPlanStorage)
_enable!(model) = Base.invokelatest(_S().enable_growth_plan_storage!, model; payload=:preboxed)
const PAYLOAD_FIELDS = (:spec, :applies_to, :target_matcher, :timestep, :clock, :model_overrides)

function _plans(simulation; readonly=false)
    result = Dict{Symbol,Any}()
    for application in simulation.compiled.applications
        plan = application.plan
        @test plan isa _S().PreboxedApplicationPlan
        @test ismutabletype(typeof(plan))
        @test fieldnames(typeof(plan)) == fieldnames(Base.unwrap_unionall(PSE.CompiledApplicationPlan))
        @test all(name -> isconst(typeof(plan), name), fieldnames(typeof(plan)))
        @test simulation.compiled.scenario_plan.applications_by_id[application.id] === plan
        payload = map(name -> getfield(plan, name), PAYLOAD_FIELDS)
        @test map(typeof, payload) == Tuple(typeof(plan).parameters)
        @test all(name -> fieldtype(typeof(plan), name) === Any, PAYLOAD_FIELDS)
        @test typeof(PSE.model_(plan.spec)) === typeof(plan.spec).parameters[1]
        @test PSE.model_(plan.spec) === PSE.model_(simulation.model.applications[plan.slot])
        if readonly
            for name in fieldnames(typeof(plan))
                @test_throws ErrorException setfield!(plan, name, getfield(plan, name))
            end
        end
        result[application.id] = (; plan, payload)
    end
    @test !isempty(result)
    return result
end
function _same_plans(simulation, retained)
    current = _plans(simulation)
    @test keys(current) == keys(retained)
    for id in keys(current)
        @test current[id].plan === retained[id].plan
        @test all(index -> current[id].payload[index] === retained[id].payload[index], 1:6)
    end
    return nothing
end
function _evidence(simulation)
    actual = length(_plans(simulation))
    report = Base.invokelatest(_S().growth_plan_storage_report, simulation)
    @test report.enabled
    @test report.payload_mode === :preboxed
    @test report.heap_plans_constructed > 0
    @test report.preboxed_plans_constructed > 0
    @test report.current_preboxed_plans == actual > 0
    return (; actual_preboxed_plans=actual, report)
end
function _generic_growth!(model, step)
    step == 2 || return nothing
    PSE.register_object!(model, _C()._unit(2))
    PSE.register_object!(model, PSE.Object(:new; kind=:growth_input_gatherer))
    PSE.register_object!(model, _C()._unit(3; parent=:new))
    return nothing
end

"""One independent paired case, using original scientific methods and refs.
Select :generic, :pb, :xp, :initializer, :mixed_cadence or :distributed.
The generic case grows from singleton to Many and resolves OptionalOne.
"""
function preboxed_plan_checks(case::Symbol=:generic; outputs=:all)
    C, F = _C(), _F()
    kind = case in (:pb, :xp) ? case : :generic
    steps = case === :mixed_cadence ? 4 : case === :initializer ? 3 : 2
    if case in (:pb, :xp)
        H = getfield(Main, :DirectPlannerMeasurements)
        config = H.construct_config(case; steps, nobjects=2, outputs)
        left, right = F.construct_fixture(case, config), F.construct_fixture(case, config)
        left_model, right_model = left.model, right.model
    elseif case === :generic
        left_model, right_model = C._generic_fixture(1), C._generic_fixture(1)
    elseif case in (:initializer, :mixed_cadence)
        N = getfield(Main, :NewbornPreparationChecks)
        cadence = case === :mixed_cadence ? Hour(2) : Hour(1)
        left_model = N.preparation_fixture(; source_every=cadence).model
        right_model = N.preparation_fixture(; source_every=cadence).model
    elseif case === :distributed
        D = getfield(Main, :NewbornDistributedChecks)
        left_model, right_model = D.distributed_fixture(:from_status), D.distributed_fixture(:from_status)
    else
        throw(ArgumentError("Unknown preboxed plan case: $case"))
    end
    reference = PSE.run!(left_model; steps=0, outputs)
    candidate = C._prepare(right_model; enable! = _enable!, outputs)
    @testset "Preboxed metadata keeps original $case behavior" begin
        @test all(application -> application.plan isa PSE.CompiledApplicationPlan, reference.compiled.applications)
        retained = _plans(candidate; readonly=true)
        previous = C._initial_pair(reference, candidate; kind)
        for step in 1:steps
            case === :generic && (_generic_growth!(reference.model, step); _generic_growth!(candidate.model, step))
            PSE.step!(reference); PSE.step!(candidate)
            previous = C._pair_state(reference, candidate, previous; kind)
            C._live_bindings(candidate)
            _same_plans(candidate, retained)
        end
        if case in (:pb, :xp)
            CR = getfield(Main, :CompiledRegionsExperiment)
            @test CR.downstream_work_report(candidate, right.initial_ids) == CR.downstream_work_report(reference, left.initial_ids)
        end
    end
    return (; passed=true, case, steps, outputs, evidence=_evidence(candidate),
        oracle=:ordinary_per_step_exact_state_history_rng_live_refs_and_original_payload_identity)
end

"""Optional combination: real partition report plus inspected preboxed plans."""
function preboxed_plan_partition_checks(; outputs=:all)
    input = getfield(Main, :GrowthInputReuse)
    enable! = model -> begin
        _enable!(model)
        Base.invokelatest(input.enable_growth_input_reuse!, model)
    end
    storage = Any[]
    report = simulation -> begin
        push!(storage, _evidence(simulation))
        Base.invokelatest(input.growth_input_reuse_report, simulation)
    end
    result = _C().growth_input_generic_checks(; enable!, report, outputs)
    return (; passed=true, partition=result, storage,
        interpretation=:independent_actual_storage_and_partition_coverage)
end

end # module
