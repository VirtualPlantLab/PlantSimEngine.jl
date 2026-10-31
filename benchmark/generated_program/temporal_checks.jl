# Separate final gate for complete independent-object trajectories.

function _temporal_checked(builder; steps::Int=4, outputs=:all,
    prepared::Bool=false)
    reference = PSE.run!(builder(); steps, outputs)
    simulation = PSE.run!(builder(); steps=0, outputs)
    program = compile_temporal_program(simulation; prepared)
    advance_program!(program; steps)
    expected, observed = fingerprint(reference), fingerprint(simulation)
    @test isequal(observed.states, expected.states)
    @test isequal(observed.histories, expected.histories)
    @test observed.step == expected.step
    @test simulation.execution_plan.schedule.last_step ==
        reference.execution_plan.schedule.last_step
    return (; reference, simulation, program, observed, report=strategy_report(program))
end

"""
    run_temporal_checks(; prepared_modes=(false,true), features=true,
                          overrides=true, interoperability=true, refresh=true)

Small complete-state/history gate for object-outer/time-inner execution. All
scientific methods are the same generic methods executed by normal PSE.
"""
function run_temporal_checks(; prepared_modes=(false, true),
    value_cases=((Float32, 1), (Float64, 5)), output_modes=(:none, :all, :selected),
    features::Bool=true, overrides::Bool=true, interoperability::Bool=true,
    refresh::Bool=true)
    reports = NamedTuple[]
    @testset "independent temporal trajectories preserve PSE observations" begin
        for prepared in prepared_modes, (T, nobjects) in value_cases,
            output_mode in output_modes
            builder = () -> fixture_builder(; nobjects, nmodels=3, value_type=T, extras=1)
            result = _temporal_checked(builder; prepared, steps=4,
                outputs=_experiment_output(output_mode, 3))
            @test result.report.temporal_selected
            @test result.report.temporal_kernels == 3
            @test result.report.temporal_steps == 4
            @test result.report.temporal_fallback_steps == 0
            check_fixture_counts(result.observed; nobjects, nmodels=3,
                steps=4, value_type=T)
            push!(reports, (; case=:local_chain, prepared, nobjects,
                value_type=string(T), output_mode, report=result.report))
        end

        if overrides
            for prepared in prepared_modes
                result = _temporal_checked(_column_override_fixture; prepared)
                @test result.report.temporal_selected
                @test result.report.column_per_row_model_payloads >= 1
                @test result.observed.states[PSE.ObjectId(:override_unit)].stage_1 !=
                    result.observed.states[PSE.ObjectId(:default_unit)].stage_1
                push!(reports, (; case=:per_row_override, prepared, nobjects=3,
                    value_type="Float64", output_mode=:all, report=result.report))
            end
        end

        if features
            prepared = last(prepared_modes)
            cases = (
                (name=:within_row_alias, builder=within_row_alias_fixture, selected=true),
                (name=:updates, builder=updates_fixture, selected=true),
                (name=:fresh_forcing, builder=_column_forcing_fixture, selected=true),
                (name=:different_phase, builder=phase_fixture, selected=false),
                (name=:cross_object_reduction, builder=reduction_fixture, selected=false),
                (name=:cross_row_alias, builder=alias_fixture, selected=false),
                (name=:calls, builder=call_fixture, selected=false),
                (name=:temporal_input, builder=temporal_fixture, selected=false),
                (name=:growth, builder=growth_fixture, selected=false),
                (name=:ordered_effect, builder=ordered_effect_fixture, selected=false),
                (name=:distributed, builder=distributed_fixture, selected=false),
            )
            for case in cases
                result = _temporal_checked(case.builder; prepared)
                @test result.report.temporal_selected == case.selected
                @test result.report.temporal_steps == (case.selected ? 4 : 0)
                @test result.report.temporal_fallback_steps == (case.selected ? 0 : 4)
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
                end
                push!(reports, (; case=case.name, prepared, nobjects=nothing,
                    value_type="Float64", output_mode=:all, report=result.report))
            end
        end

        if interoperability
            for prepared in prepared_modes
                reference = PSE.run!(fixture_builder(; nobjects=5, nmodels=2);
                    steps=0, outputs=:all)
                simulation = PSE.run!(fixture_builder(; nobjects=5, nmodels=2);
                    steps=0, outputs=:all)
                program = compile_temporal_program(simulation; prepared)
                advance_program!(program; steps=2)
                PSE.continue!(reference; steps=2)
                @test isequal(fingerprint(simulation), fingerprint(reference))
                PSE.continue!(simulation; steps=2)
                PSE.continue!(reference; steps=2)
                @test isequal(fingerprint(simulation), fingerprint(reference))
                advance_program!(program; steps=2)
                PSE.continue!(reference; steps=2)
                @test isequal(fingerprint(simulation), fingerprint(reference))
                @test simulation.execution_plan.schedule.last_step == 6
                @test simulation.compiled.execution_generation ==
                    reference.compiled.execution_generation
                report = strategy_report(program)
                @test report.temporal_selected
                @test report.temporal_steps == 4
                @test report.temporal_fallback_steps == 0
                push!(reports, (; case=:ordinary_continuation_interoperability,
                    prepared, nobjects=5, value_type="Float64", output_mode=:all, report))
            end
        end

        if refresh
            prepared = last(prepared_modes)
            reference_model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            reference = PSE.run!(reference_model; steps=0, outputs=:all)
            simulation = PSE.run!(model; steps=0, outputs=:all)
            program = compile_temporal_program(simulation; prepared)
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            for scene in (reference_model, model)
                status = PSE.model_status(scene, 1)
                status.stage_1 = -7.0
                status.unused_1 = 31.0
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            for scene in (reference_model, model)
                PSE.register_object!(scene, PSE.Object(91; kind=:arbitrary_unit,
                    status=_chain_status(2, Float64, 1, 91)))
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            @test PSE.final_state(simulation, 91).visits_1 == 1
            for scene in (reference_model, model)
                PSE.remove_object!(scene, 2)
            end
            advance_program!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(reference))
            @test !haskey(fingerprint(simulation).states, PSE.ObjectId(2))
            @test haskey(fingerprint(simulation).histories,
                (:stage_1, PSE.ObjectId(2), :stage_1))
            report = strategy_report(program)
            @test report.temporal_selected
            @test report.rebuilds >= 2
            push!(reports, (; case=:canonical_and_membership_refresh, prepared,
                nobjects=nothing, value_type="Float64", output_mode=:all, report))
        end
    end
    return (; cases=length(reports), reports)
end
