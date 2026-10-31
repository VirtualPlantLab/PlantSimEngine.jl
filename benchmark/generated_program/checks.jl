# Cheap structural/correctness gates. No timings or package installs here.

function _experiment_output(mode::Symbol, nmodels::Int)
    mode === :selected && return PSE.OutputRequest(
        PSE.Many(kind=:arbitrary_unit), _stage_name(nmodels);
        name=:selected_stage, application=_stage_name(nmodels))
    mode in (:none, :all) || throw(ArgumentError("Unknown output mode $(mode)"))
    return mode
end

function _checked_equivalence(builder; strategy::Symbol, packed::Bool,
    steps::Int=3, outputs=:all, block_size::Int=4, compiler=compile_program)
    reference = PSE.run!(builder(); steps, outputs)
    scene = builder()
    simulation = PSE.run!(scene; steps=0, outputs)
    program = compiler(simulation; strategy, packed, block_size)
    advance_program!(program; steps)
    expected = fingerprint(reference)
    observed = fingerprint(simulation)
    @test isequal(observed.states, expected.states)
    @test isequal(observed.histories, expected.histories)
    @test observed.step == expected.step
    return (; reference, simulation, program, observed,
        report=strategy_report(program))
end

"""Small exact-state/history matrix; caller may select a smaller first screen."""
function run_local_checks(; strategies=(:typed, :fused, :monolith),
    packings=(false, true), value_types=(Float32, Float64),
    object_counts=(1, 5), output_modes=(:none, :all, :selected),
    steps::Int=3, nmodels::Int=3, environment_used::Bool=false)
    reports = NamedTuple[]
    @testset "generic generated program local chain" begin
        for T in value_types, nobjects in object_counts,
            output_mode in output_modes, strategy in strategies, packed in packings
            fixture = () -> fixture_builder(; nobjects, nmodels, value_type=T,
                extras=2, environment_used)
            result = _checked_equivalence(fixture; strategy, packed, steps,
                outputs=_experiment_output(output_mode, nmodels))
            @test result.report.direct_applications == nmodels
            @test result.report.ordered_applications == 0
            @test result.report.packed_selected == packed
            if strategy === :typed
                @test result.report.fused_regions == 0
            elseif nmodels > 1
                @test result.report.fused_applications > 0
            end
            check_fixture_counts(result.observed; nobjects, nmodels, steps,
                value_type=T)
            @test all(getproperty(state, Symbol(:unused_, 1)) === T(index + 1)
                for (index, state) in ((id.value, state)
                    for (id, state) in result.observed.states))
            push!(reports, (; value_type=string(T), nobjects, output_mode,
                strategy, packed, report=result.report))
        end
    end
    return (; cases=length(reports), reports)
end

"""Check ordered features through the generated program's general boundaries."""
function run_feature_checks(; strategies=(:typed, :fused, :monolith),
    packings=(false, true), steps::Int=4)
    cases = (
        (name=:cross_object_reduction, builder=reduction_fixture),
        (name=:trial_and_acceptance, builder=call_fixture),
        (name=:multirate_previous_step, builder=temporal_fixture),
        (name=:same_step_growth, builder=growth_fixture),
        (name=:intentional_updates, builder=updates_fixture),
        (name=:cross_row_alias, builder=alias_fixture),
        (name=:within_row_alias, builder=within_row_alias_fixture),
        (name=:ordered_shared_effect, builder=ordered_effect_fixture),
        (name=:same_period_different_phase, builder=phase_fixture),
        (name=:distributed_outputs, builder=distributed_fixture),
    )
    reports = NamedTuple[]
    @testset "generated program feature barriers" begin
        for case in cases, strategy in strategies, packed in packings
            result = _checked_equivalence(case.builder; strategy, packed, steps,
                outputs=:all)
            if case.name === :trial_and_acceptance
                state = result.observed.states[PSE.ObjectId(:worker)]
                @test state.visits == 2 * steps
                @test state.value == 3.0
                samples = result.observed.histories[(:worker, PSE.ObjectId(:worker), :value)]
                @test length(samples) == steps
                @test all(last(sample) == 3.0 for sample in samples)
            elseif case.name === :same_step_growth
                state = result.observed.states[PSE.ObjectId(:new_unit)]
                # Growth occurs at step 2; applications later in that same
                # timestep must already see the newborn object.
                @test state.visits_1 == steps - 1
                @test state.visits_2 == steps - 1
            elseif case.name === :cross_object_reduction
                @test result.observed.states[PSE.ObjectId(:aggregate)].source_count == 5
            elseif case.name === :intentional_updates
                @test result.observed.states[PSE.ObjectId(1)].updated == 11 * steps
                first_writer = result.observed.histories[(:first, PSE.ObjectId(1), :updated)]
                second_writer = result.observed.histories[(:second, PSE.ObjectId(1), :updated)]
                @test last(last(first_writer)) == 11 * (steps - 1) + 1
                @test last(last(second_writer)) == 11 * steps
            elseif case.name === :cross_row_alias
                @test result.report.direct_applications == 0
                @test !result.report.packed_selected
                @test result.report.fused_regions == 0
            elseif case.name === :ordered_shared_effect
                @test result.report.ordered_applications == 2
                @test result.report.fused_regions == 0
            elseif case.name === :same_period_different_phase
                @test result.report.direct_applications == 2
                @test result.report.fused_regions == 0
            elseif case.name === :distributed_outputs
                @test result.observed.states[PSE.ObjectId(1)].seen == steps + 1.0
            end
            push!(reports, (; case=case.name, strategy, packed,
                report=result.report))
        end
    end
    return (; cases=length(reports), reports)
end

"""Additional local-value lowering gate; no benchmark work is performed here."""
function run_scalar_checks(; strategies=(:fused, :monolith),
    packings=(false, true), value_types=(Float32, Float64),
    object_counts=(1, 5), output_modes=(:none, :all, :selected),
    steps::Int=3, nmodels::Int=3, feature_cases::Bool=true)
    reports = NamedTuple[]
    @testset "scalar-local generated program" begin
        for T in value_types, nobjects in object_counts, output_mode in output_modes,
            strategy in strategies, packed in packings
            builder = () -> fixture_builder(; nobjects, nmodels, value_type=T, extras=2)
            result = _checked_equivalence(builder; strategy, packed, steps,
                compiler=compile_local_program,
                outputs=_experiment_output(output_mode, nmodels))
            @test result.report.scalar_regions > 0
            @test result.report.scalar_applications == nmodels
            @test result.report.packed_selected == packed
            check_fixture_counts(result.observed; nobjects, nmodels, steps, value_type=T)
            push!(reports, (; case=:local_chain, value_type=string(T),
                nobjects, output_mode, strategy, packed, report=result.report))
        end
        if feature_cases
            cases = (
                (name=:updates, builder=updates_fixture),
                (name=:within_row_alias, builder=within_row_alias_fixture),
                (name=:cross_row_alias, builder=alias_fixture),
                (name=:reduction, builder=reduction_fixture),
                (name=:calls, builder=call_fixture),
                (name=:temporal, builder=temporal_fixture),
                (name=:growth, builder=growth_fixture),
                (name=:ordered_effect, builder=ordered_effect_fixture),
                (name=:cadence_phase, builder=phase_fixture),
                (name=:distributed_outputs, builder=distributed_fixture),
            )
            for case in cases, strategy in strategies, packed in packings
                result = _checked_equivalence(case.builder; strategy, packed,
                    steps=max(steps, 4), outputs=:all, compiler=compile_local_program)
                if case.name in (:updates, :within_row_alias, :reduction)
                    @test result.report.scalar_regions > 0
                elseif case.name in (:cross_row_alias, :ordered_effect, :cadence_phase)
                    @test result.report.scalar_regions == 0
                end
                if case.name === :updates
                    first_writer = result.observed.histories[(:first, PSE.ObjectId(1), :updated)]
                    second_writer = result.observed.histories[(:second, PSE.ObjectId(1), :updated)]
                    @test last(last(first_writer)) == 11 * (max(steps, 4) - 1) + 1
                    @test last(last(second_writer)) == 11 * max(steps, 4)
                elseif case.name === :within_row_alias
                    state = result.observed.states[PSE.ObjectId(1)]
                    @test state.stage_1 == state.stage_2
                end
                push!(reports, (; case=case.name, value_type="Float64", nobjects=nothing,
                    output_mode=:all, strategy, packed, report=result.report))
            end
        end
    end
    return (; cases=length(reports), reports)
end

"""Canonical mutations and membership changes between compiled advances."""
function run_refresh_checks(; strategies=(:typed, :fused, :monolith),
    packings=(false, true))
    reports = NamedTuple[]
    @testset "generated program external state and topology refresh" begin
        for strategy in strategies, packed in packings
            baseline_model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            compiled_model = fixture_builder(; nobjects=3, nmodels=2, extras=1)
            baseline = PSE.run!(baseline_model; steps=0, outputs=:all)
            simulation = PSE.run!(compiled_model; steps=0, outputs=:all)
            program = compile_program(simulation; strategy, packed)
            PSE.continue!(baseline; steps=1)
            advance_program!(program; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(baseline))

            for model in (baseline_model, compiled_model)
                status = PSE.model_status(model, 1)
                status.stage_1 = -3.0
                status.unused_1 = 17.0
            end
            PSE.continue!(baseline; steps=1)
            advance_program!(program; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(baseline))

            for model in (baseline_model, compiled_model)
                PSE.register_object!(model, PSE.Object(91; scale=:unit,
                    kind=:arbitrary_unit, status=_chain_status(2, Float64, 1, 91)))
            end
            PSE.continue!(baseline; steps=1)
            advance_program!(program; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(baseline))
            @test PSE.final_state(simulation, 91).visits_1 == 1

            for model in (baseline_model, compiled_model)
                PSE.remove_object!(model, 2)
            end
            PSE.continue!(baseline; steps=1)
            advance_program!(program; steps=1)
            @test isequal(fingerprint(simulation), fingerprint(baseline))
            @test !haskey(fingerprint(simulation).states, PSE.ObjectId(2))
            @test haskey(fingerprint(simulation).histories,
                (:stage_1, PSE.ObjectId(2), :stage_1))
            push!(reports, (; strategy, packed, report=strategy_report(program)))
        end
    end
    return (; cases=length(reports), reports)
end

"""Storage test independent from driver: preserve exact reference aliases."""
function run_packed_storage_checks()
    @testset "packed state exact aliases and synchronization" begin
        for T in (Float32, Float64)
            shared = Ref(T(2))
            independent = Ref(T(3))
            originals = [PSE.Status((x=shared, y=shared)),
                PSE.Status((x=shared, y=independent))]
            store = prepare_packed_rows(originals)
            rows = packed_statuses(store)
            rows[1].x = T(7)
            @test rows[1].y === T(7)
            @test rows[2].x === T(7)
            @test rows[2].y === T(3)
            @test shared[] === T(2)
            push_packed!(store)
            @test shared[] === T(7)
            @test independent[] === T(3)
            independent[] = T(11)
            shared[] = T(13)
            pull_packed!(store)
            @test rows[1].x === T(13)
            @test rows[1].y === T(13)
            @test rows[2].x === T(13)
            @test rows[2].y === T(11)
            report = packed_report(store)
            @test report.unique_cells == 2
            @test report.cross_row_aliases > 0
        end
        mutable_value = PSE.Status(x=[1.0, 2.0])
        @test_throws ArgumentError prepare_packed_rows([mutable_value])
        @test mutable_value.x == [1.0, 2.0]
        @test_throws ArgumentError prepare_packed_rows([PSE.Status(x=1.0), PSE.Status(y=2.0)])
        @test_throws ArgumentError prepare_packed_rows(PSE.Status[])
    end
    return (; numeric_types=2, alias_cells=2, unsupported_schemas_rejected=true)
end
