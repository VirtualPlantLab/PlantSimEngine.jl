# Separate, small gate for cadence specialization. Included after cadence_driver.

const REGULAR_CHECK_ARMS = (
    (name=:regular_typed, strategy=:typed, packed=false, scalar=false),
    (name=:regular_fused, strategy=:fused, packed=false, scalar=false),
    (name=:regular_fused_packed, strategy=:fused, packed=true, scalar=false),
    (name=:regular_scalar_monolith_packed, strategy=:monolith, packed=true, scalar=true),
)

function _prepare_regular_check(model, arm; outputs=:all)
    simulation = PSE.run!(model; steps=0, outputs)
    program = compile_regular_program(simulation;
        strategy=arm.strategy, packed=arm.packed, scalar=arm.scalar)
    return (; simulation, program)
end

function _regular_check_equal(simulation, reference)
    @test isequal(fingerprint(simulation), fingerprint(reference))
    @test simulation.execution_plan.schedule.last_step ==
        reference.execution_plan.schedule.last_step
    return nothing
end

function _regular_forcing_fixture(::Type{T}, nobjects::Int, steps::Int) where {T}
    objects = [PSE.Object(index; kind=:arbitrary_unit,
        status=_chain_status(2, T, 0, index)) for index in 1:nobjects]
    applications = [PSE.ModelSpec(ChainStage{index,T,true}(T(0.5), T(index));
        name=_stage_name(index), on=PSE.Many(kind=:arbitrary_unit), every=Hour(1))
        for index in 1:2]
    rows = [(driver=T(step + 1), duration=Hour(1)) for step in 1:steps]
    return PSE.CompositeModel(objects...; applications, environment=rows)
end

"""
    run_regular_checks(; arms=REGULAR_CHECK_ARMS, refresh=true, fallbacks=true,
                         varying_environment=true)

Exact state/history and clock interoperability gate for always-due lowering.
One-object Float32 and five-object Float64 cases stay small. No timings run here.
"""
function run_regular_checks(; arms=REGULAR_CHECK_ARMS, refresh::Bool=true,
    fallbacks::Bool=true, varying_environment::Bool=true)
    reports = NamedTuple[]
    @testset "regular generated program clock and feature preservation" begin
        for (nobjects, T) in ((1, Float32), (5, Float64)), arm in arms
            reference = PSE.run!(fixture_builder(; nobjects, nmodels=3,
                value_type=T, extras=1); steps=0, outputs=:all)
            scene = fixture_builder(; nobjects, nmodels=3, value_type=T, extras=1)
            checked = _prepare_regular_check(scene, arm)
            simulation, program = checked.simulation, checked.program
            @test strategy_report(program).regular_selected

            advance_program!(program; steps=2)
            PSE.continue!(reference; steps=2)
            _regular_check_equal(simulation, reference)

            # Normal execution must resume a timeline advanced without the
            # scheduler, then the regular program must resume normal execution.
            PSE.continue!(simulation; steps=1)
            PSE.continue!(reference; steps=1)
            _regular_check_equal(simulation, reference)
            advance_program!(program; steps=2)
            PSE.continue!(reference; steps=2)
            _regular_check_equal(simulation, reference)
            check_fixture_counts(fingerprint(simulation); nobjects, nmodels=3,
                steps=5, value_type=T)
            report = strategy_report(program)
            @test report.regular_steps == 4
            @test report.regular_fallback_steps == 0
            @test simulation.execution_plan.schedule.due_entry_indices ==
                reference.execution_plan.schedule.due_entry_indices
            push!(reports, (; case=:clock_interoperability, arm=arm.name,
                nobjects, value_type=string(T), report))
        end

        if fallbacks
            for (name, builder) in ((:different_phase, phase_fixture),
                (:temporal, temporal_fixture), (:manual_calls, call_fixture))
                # One plain and one scalar/packed request exercise both layers
                # without multiplying every feature by the entire timing matrix.
                for arm in (first(arms), last(arms))
                    reference = PSE.run!(builder(); steps=4, outputs=:all)
                    checked = _prepare_regular_check(builder(), arm)
                    simulation, program = checked.simulation, checked.program
                    @test !strategy_report(program).regular_selected
                    advance_program!(program; steps=4)
                    _regular_check_equal(simulation, reference)
                    report = strategy_report(program)
                    @test !report.regular_selected
                    @test report.regular_steps == 0
                    @test report.regular_fallback_steps == 4
                    push!(reports, (; case=name, arm=arm.name,
                        nobjects=nothing, value_type="Float64", report))
                end
            end
        end

        if refresh
            arm = last(arms)
            baseline_model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            scene = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            reference = PSE.run!(baseline_model; steps=0, outputs=:all)
            checked = _prepare_regular_check(scene, arm)
            simulation, program = checked.simulation, checked.program
            advance_program!(program; steps=2)
            PSE.continue!(reference; steps=2)
            _regular_check_equal(simulation, reference)

            for model in (baseline_model, scene)
                status = PSE.model_status(model, 1)
                status.stage_1 = -7.0
                status.unused_1 = 23.0
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            _regular_check_equal(simulation, reference)

            for model in (baseline_model, scene)
                PSE.register_object!(model, PSE.Object(91; kind=:arbitrary_unit,
                    status=_chain_status(2, Float64, 1, 91)))
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            _regular_check_equal(simulation, reference)
            @test PSE.final_state(simulation, 91).visits_1 == 1

            for model in (baseline_model, scene)
                PSE.remove_object!(model, 2)
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            _regular_check_equal(simulation, reference)
            @test !haskey(fingerprint(simulation).states, PSE.ObjectId(2))
            @test haskey(fingerprint(simulation).histories,
                (:stage_1, PSE.ObjectId(2), :stage_1))
            report = strategy_report(program)
            @test report.regular_selected
            @test report.rebuilds >= 2
            @test report.regular_steps == 5
            push!(reports, (; case=:external_state_and_membership, arm=arm.name,
                nobjects=nothing, value_type="Float64", report))
        end

        if varying_environment
            arm = last(arms)
            reference = PSE.run!(_regular_forcing_fixture(Float64, 5, 4);
                steps=4, outputs=:all)
            checked = _prepare_regular_check(_regular_forcing_fixture(Float64, 5, 4), arm)
            advance_program!(checked.program; steps=4)
            _regular_check_equal(checked.simulation, reference)
            report = strategy_report(checked.program)
            @test report.regular_selected
            samples = fingerprint(checked.simulation).histories[
                (:stage_1, PSE.ObjectId(1), :stage_1)]
            @test last.(samples) == [2.5, 6.0, 10.5, 16.0]
            push!(reports, (; case=:fresh_forcing_rows, arm=arm.name,
                nobjects=5, value_type="Float64", report))
        end
    end
    return (; cases=length(reports), reports)
end
