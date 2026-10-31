# Focused regression for retired IDs in compact logical target views. PSE must
# skip identities before trying to materialize snapshots from the refreshed
# status-view dictionary. No retired rich target records are retained to make
# this test pass.

function _compact_lifecycle_advance!(reference, program, public_continuation)
    PSE.continue!(reference; steps=1)
    if public_continuation
        PSE.continue!(program.simulation; steps=1)
        # Reinstall current compact owners so the next edit again exercises
        # removal from a lazy view, rather than only an ordinary rebuilt group.
        _ensure_regions!(program)
    else
        advance_regions!(program; steps=1)
    end
    @test isequal(GP.fingerprint(program.simulation), GP.fingerprint(reference))
    return nothing
end

function compact_lifecycle_checks()
    isdefined(PSE, :_model_execution_target_id) || throw(ArgumentError(
        "Compact removal qualification requires the core identity-scan hook.",
    ))
    reports = NamedTuple[]
    @testset "Compact execution retires target IDs before materialization" begin
        for native in (false, true), state_strategy in (:columns, :references),
            refresh_strategy in (:rebuild, :reuse, :eager), public_continuation in (false, true)
            fixture = native_column_integration_fixture(Float64; native, nobjects=4, nmodels=2,
                echo_on=PSE.OptionalOne(id=:echo))
            control = native_column_integration_fixture(Float64; native=false,
                nobjects=4, nmodels=2, echo_on=PSE.OptionalOne(id=:echo))
            simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
            reference = PSE.run!(control.model; steps=0, outputs=:all)
            program = compile_regions(simulation; regions=true, resolved_calls=false,
                compact=true, state_strategy, refresh_strategy)
            @test region_report(program).execution_records_removed > 0
            cached_status = PSE.model_status(fixture.model, 3)
            _compact_lifecycle_advance!(reference, program, public_continuation)

            newborn_row = NamedTuple(GP._chain_status(2, Float64, 0, 91))
            newborn = native ? only(build_column_statuses([newborn_row]).statuses) :
                PSE.Status(newborn_row)
            PSE.register_object!(fixture.model, PSE.Object(91; kind=:native_unit, status=newborn))
            PSE.register_object!(control.model, PSE.Object(91; kind=:native_unit,
                status=GP._chain_status(2, Float64, 0, 91)))
            _compact_lifecycle_advance!(reference, program, public_continuation)

            # Removing an interior ID was the original failure: general refresh
            # reconstructed retired row 2 while scanning for still-active row 3.
            PSE.remove_object!(fixture.model, 2)
            PSE.remove_object!(control.model, 2)
            _compact_lifecycle_advance!(reference, program, public_continuation)
            @test cached_status === PSE.model_status(fixture.model, 3)
            cached_status.stage_1 = 17.0
            PSE.model_status(control.model, 3).stage_1 = 17.0
            native && (@test fixture.source.columns.stage_1[3] == 17.0)

            # Retire the first and final IDs too. The One consumer is removed
            # with its source, preserving a valid scenario for the Many reader.
            for scene in (fixture.model, control.model)
                PSE.remove_object!(scene, :echo)
                PSE.remove_object!(scene, 1)
            end
            _compact_lifecycle_advance!(reference, program, public_continuation)
            PSE.remove_object!(fixture.model, 91)
            PSE.remove_object!(control.model, 91)
            _compact_lifecycle_advance!(reference, program, public_continuation)
            for scene in (fixture.model, control.model)
                PSE.remove_object!(scene, 3)
                PSE.remove_object!(scene, 4)
            end
            _compact_lifecycle_advance!(reference, program, public_continuation)
            observed = GP.fingerprint(simulation)
            @test Set(keys(observed.states)) == Set([PSE.ObjectId(:sum)])
            @test PSE.model_status(fixture.model, :sum).source_count == 0
            @test PSE.model_status(fixture.model, :sum).total == 0.0
            @test haskey(observed.histories, (:stage_1, PSE.ObjectId(2), :stage_1))
            @test haskey(observed.histories, (:echo, PSE.ObjectId(:echo), :observed))
            push!(reports, (native, state_strategy, refresh_strategy, public_continuation,
                passed=true, steps=simulation.current_step, rebuilds=program.rebuilds,
                retained_removed_histories=true))
        end
    end
    return (; cases=length(reports), reports)
end
