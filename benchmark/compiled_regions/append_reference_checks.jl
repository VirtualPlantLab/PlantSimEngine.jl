# Positive ownership and parity gates. Include inside CompiledRegionsExperiment
# after append_reference_regions.jl; execution belongs to the controlling Kaimon
# session, never to a detached Julia process.

"""Untimed real-package parity smoke with actual append coverage counters."""
function append_reference_smoke(builder; steps::Int=4, outputs=:none)
    reference = PSE.run!(builder(); steps=0, outputs)
    simulation = PSE.run!(builder(); steps=0, outputs)
    program = compile_regions(simulation; resolved_calls=true,
        compact=true, state_strategy=:references, refresh_strategy=:append)
    for _ in 1:steps
        PSE.continue!(reference; steps=1)
        advance_regions!(program; steps=1)
        @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
    end
    report = region_report(program)
    return (passed=true, steps, outputs,
        column_rows=report.column_row_executions,
        append_batch_commits=report.append_batch_commits,
        append_row_memberships=report.append_row_memberships,
        call_fast_hits=report.call_fast_hits,
        call_execution=:ordinary_feature_path,
        zero_commits_means_no_qualified_append=report.append_batch_commits == 0,
        final_objects=length(PSE.object_ids(simulation.model)))
end

function append_reference_checks()
    reports = NamedTuple[]
    @testset "Pure additions extend installed live-reference owners" begin
        for T in (Float32, Float64), outputs in (:none, :all),
            public_continuation in (false, true)
            builder = () -> GP.fixture_builder(nobjects=3, nmodels=2,
                value_type=T, extras=0)
            reference = PSE.run!(builder(); steps=0, outputs)
            simulation = PSE.run!(builder(); steps=0, outputs)
            program = compile_regions(simulation; resolved_calls=true,
                compact=true, state_strategy=:references, refresh_strategy=:append)
            advance_regions!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            batches = [batch for batch in simulation.execution_plan.batches
                if batch isa RegionColumnBatch]
            @test length(batches) == 2
            columns = [values(batch.state.data.references) for batch in batches]
            ids = [batch.targets.object_ids for batch in batches]
            cached_status = PSE.model_status(simulation.model, 1)
            for scene in (reference.model, simulation.model)
                PSE.register_object!(scene, PSE.Object(4; scale=:unit, kind=:arbitrary_unit,
                    status=GP._chain_status(2, T, 0, 4)))
            end
            PSE.continue!(reference; steps=1)
            if public_continuation
                PSE.continue!(simulation; steps=1)
                _ensure_regions!(program)
            else
                advance_regions!(program; steps=1)
            end
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            @test all(batch -> batch in simulation.execution_plan.batches, batches)
            for (batch, old_columns, old_ids) in zip(batches, columns, ids)
                @test batch.targets.object_ids === old_ids
                @test batch.targets.object_ids == PSE.ObjectId.([1, 2, 3, 4])
                @test all(current === previous for (current, previous) in
                    zip(values(batch.state.data.references), old_columns))
                @test batch.state.data.nrows == 4
                @test all(length(column) == 4 for column in old_columns)
                @test batch.targets.factory.compiled === simulation.compiled
                @test batch.targets.factory.environment_bindings === simulation.environment_bindings
            end
            @test cached_status === PSE.model_status(simulation.model, 1)
            @test PSE.model_status(simulation.model, 4).visits_1 == 1
            report = region_report(program)
            @test report.append_batch_commits == 2
            @test report.append_row_memberships == 2
            @test report.call_fast_hits == 0
            @test report.append_scheduler === :ordinary
            @test !report.canonical_scalar_copy_retained
            # A non-addition still takes ordinary lifecycle refresh, including
            # historical samples for the removed object when retention is on.
            for scene in (reference.model, simulation.model)
                PSE.remove_object!(scene, 2)
            end
            advance_regions!(program; steps=1)
            PSE.continue!(reference; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            @test !(PSE.ObjectId(2) in keys(GP.fingerprint(simulation).states))
            push!(reports, (value_type=T, outputs, public_continuation,
                append_batch_commits=report.append_batch_commits,
                append_row_memberships=report.append_row_memberships, passed=true))
        end

        # Public continuation must refresh the otherwise unused factory and
        # dispatch context of an unaffected compact group too. No _ensure call
        # intervenes between lifecycle events and these ownership assertions.
        builder = () -> PSE.CompositeModel(
            PSE.Object(1; kind=:growing, status=GP._chain_status(1, Float64, 0, 1)),
            PSE.Object(:stationary; status=GP._chain_status(1, Float64, 0, 1));
            applications=(
                PSE.ModelSpec(GP.ChainStage{1,Float64,false}(0.5, 1.0);
                    name=:growing, on=PSE.Many(kind=:growing), every=Hour(1)),
                PSE.ModelSpec(GP.ChainStage{1,Float64,false}(0.5, 1.0);
                    name=:stationary, on=PSE.One(id=:stationary), every=Hour(1)),
            ), environment=(duration=Hour(1),))
        reference = PSE.run!(builder(); steps=0, outputs=:all)
        simulation = PSE.run!(builder(); steps=0, outputs=:all)
        program = compile_regions(simulation; resolved_calls=false,
            compact=true, state_strategy=:references, refresh_strategy=:append)
        stationary = only(batch for batch in simulation.execution_plan.batches
            if batch.application.id === :stationary)
        for addition in (true, false)
            for scene in (reference.model, simulation.model)
                if addition
                    PSE.register_object!(scene, PSE.Object(2; kind=:growing,
                        status=GP._chain_status(1, Float64, 0, 2)))
                else
                    PSE.remove_object!(scene, 2)
                end
            end
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            @test stationary in simulation.execution_plan.batches
            @test stationary.targets.factory.compiled === simulation.compiled
            @test stationary.targets.factory.environment_bindings === simulation.environment_bindings
            @test stationary.kernel.context.compiled === simulation.compiled
            @test stationary.kernel.context.environment_bindings === simulation.environment_bindings
        end
        push!(reports, (case=:unchanged_owner_control_refresh, passed=true))
    end
    return (; cases=length(reports), reports)
end
