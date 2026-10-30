# Separate small gate for direct-column execution, after column_driver.jl.

function _column_checked(builder; strategy::Symbol=:monolith, steps::Int=3,
    outputs=:all)
    reference = PSE.run!(builder(); steps, outputs)
    simulation = PSE.run!(builder(); steps=0, outputs)
    program = compile_column_program(simulation; strategy)
    advance_program!(program; steps)
    expected, observed = fingerprint(reference), fingerprint(simulation)
    @test isequal(observed.states, expected.states)
    @test isequal(observed.histories, expected.histories)
    @test observed.step == expected.step
    return (; reference, simulation, program, observed, report=strategy_report(program))
end

"""One genuine same-concrete-type model Override among otherwise shared rows."""
function _column_override_fixture(::Type{T}=Float64) where {T}
    applications = Tuple(PSE.ModelSpec(ChainStage{index,T,false}(T(0.5), T(index));
        name=_stage_name(index), on=PSE.Many(kind=:arbitrary_unit), every=Hour(1))
        for index in 1:2)
    template = PSE.CompositeModelTemplate(applications)
    instance = PSE.ObjectInstance(:instance, template;
        root=PSE.Object(:unit_group; status=PSE.Status()),
        objects=(
            PSE.Object(:default_unit; parent=:unit_group, kind=:arbitrary_unit,
                status=_chain_status(2, T, 0, 1)),
            PSE.Object(:override_unit; parent=:unit_group, kind=:arbitrary_unit,
                status=_chain_status(2, T, 0, 2)),
            PSE.Object(:another_unit; parent=:unit_group, kind=:arbitrary_unit,
                status=_chain_status(2, T, 0, 3)),
        ),
        object_overrides=(PSE.Override(object=:override_unit, application=:stage_1,
            model=ChainStage{1,T,false}(T(1.5), T(7))),))
    return PSE.CompositeModel(instance; environment=(duration=Hour(1),))
end

function _column_forcing_fixture()
    objects = [PSE.Object(index; kind=:arbitrary_unit,
        status=_chain_status(2, Float64, 0, index)) for index in 1:5]
    applications = Tuple(PSE.ModelSpec(ChainStage{index,Float64,true}(0.5, Float64(index));
        name=_stage_name(index), on=PSE.Many(kind=:arbitrary_unit), every=Hour(1))
        for index in 1:2)
    rows = [(driver=Float64(step + 1), duration=Hour(1)) for step in 1:4]
    return PSE.CompositeModel(objects...; applications, environment=rows)
end

"""
    run_column_checks(; strategies=(:typed,:fused,:monolith), features=true,
                        overrides=true, refresh=true)

Small exact-state/history gate for typed columns. Every scientific method is an
ordinary fixture kernel also used by the original executor. No timings run here.
"""
function run_column_checks(; strategies=(:typed, :fused, :monolith),
    value_cases=((Float32, 1), (Float64, 5)), output_modes=(:none, :all, :selected),
    features::Bool=true, overrides::Bool=true, refresh::Bool=true)
    reports = NamedTuple[]
    @testset "direct-column generic kernels and semantic boundaries" begin
        for (T, nobjects) in value_cases, output_mode in output_modes,
            strategy in strategies
            builder = () -> fixture_builder(; nobjects, nmodels=3, value_type=T, extras=1)
            result = _column_checked(builder; strategy, steps=3,
                outputs=_experiment_output(output_mode, 3))
            report = result.report
            @test report.column_selected
            @test report.column_applications == 3
            @test report.column_shared_model_payloads == 3
            @test report.column_per_row_model_payloads == 0
            check_fixture_counts(result.observed; nobjects, nmodels=3,
                steps=3, value_type=T)
            push!(reports, (; case=:local_chain, strategy, nobjects,
                value_type=string(T), output_mode, report))
        end

        if overrides
            for strategy in strategies
                result = _column_checked(_column_override_fixture; strategy, steps=3)
                @test result.report.column_selected
                @test result.report.column_per_row_model_payloads >= 1
                @test result.report.column_shared_model_payloads >= 1
                @test result.observed.states[PSE.ObjectId(:override_unit)].stage_1 !=
                    result.observed.states[PSE.ObjectId(:default_unit)].stage_1
                push!(reports, (; case=:per_row_override, strategy, nobjects=3,
                    value_type="Float64", output_mode=:all, report=result.report))
            end
        end

        if features
            cases = (
                (name=:within_row_alias, builder=within_row_alias_fixture, selected=true),
                (name=:updates, builder=updates_fixture, selected=true),
                (name=:different_phase, builder=phase_fixture, selected=true),
                (name=:fresh_forcing, builder=_column_forcing_fixture, selected=true),
                (name=:cross_row_alias, builder=alias_fixture, selected=false),
                (name=:calls, builder=call_fixture, selected=false),
                (name=:temporal, builder=temporal_fixture, selected=false),
                (name=:growth, builder=growth_fixture, selected=false),
                (name=:ordered_effect, builder=ordered_effect_fixture, selected=false),
                (name=:distributed, builder=distributed_fixture, selected=false),
            )
            strategy = last(strategies)
            for case in cases
                result = _column_checked(case.builder; strategy, steps=4)
                @test result.report.column_selected == case.selected
                if case.name === :within_row_alias
                    state = result.observed.states[PSE.ObjectId(1)]
                    @test state.stage_1 == state.stage_2
                elseif case.name === :updates
                    first_writer = result.observed.histories[(:first, PSE.ObjectId(1), :updated)]
                    second_writer = result.observed.histories[(:second, PSE.ObjectId(1), :updated)]
                    @test last(last(first_writer)) == 34.0
                    @test last(last(second_writer)) == 44.0
                elseif case.name === :fresh_forcing
                    samples = result.observed.histories[(:stage_1, PSE.ObjectId(1), :stage_1)]
                    @test last.(samples) == [2.5, 6.0, 10.5, 16.0]
                elseif case.name === :different_phase
                    @test result.report.column_regions == 2
                end
                push!(reports, (; case=case.name, strategy, nobjects=nothing,
                    value_type="Float64", output_mode=:all, report=result.report))
            end
        end

        if refresh
            strategy = last(strategies)
            baseline_model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            reference = PSE.run!(baseline_model; steps=0, outputs=:all)
            simulation = PSE.run!(model; steps=0, outputs=:all)
            program = compile_column_program(simulation; strategy)
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))

            for scene in (baseline_model, model)
                status = PSE.model_status(scene, 1)
                status.stage_1 = -7.0
                status.unused_1 = 29.0
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            for scene in (baseline_model, model)
                PSE.register_object!(scene, PSE.Object(91; kind=:arbitrary_unit,
                    status=_chain_status(2, Float64, 1, 91)))
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            @test PSE.final_state(simulation, 91).visits_1 == 1
            for scene in (baseline_model, model)
                PSE.remove_object!(scene, 2)
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            @test haskey(fingerprint(simulation).histories,
                (:stage_1, PSE.ObjectId(2), :stage_1))
            @test !haskey(fingerprint(simulation).states, PSE.ObjectId(2))
            report = strategy_report(program)
            @test report.column_selected
            @test report.rebuilds >= 2
            push!(reports, (; case=:canonical_and_membership_refresh, strategy,
                nobjects=nothing, value_type="Float64", output_mode=:all, report))
        end
    end
    return (; cases=length(reports), reports)
end
