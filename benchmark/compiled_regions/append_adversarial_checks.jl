# Independent source-review gates for append-only live-reference regions.
# Include inside CompiledRegionsExperiment after append_reference_regions.jl.
# These assertions exercise rejected transactions as well as numerical parity.

PSE.@process "region_append_adversarial_probe" verbose=false
struct AppendAdversarialProbe{K,T} <: AbstractRegion_Append_Adversarial_ProbeModel
    gain::T
end
_append_probe_names(K) = (Symbol(:append_x_, K), Symbol(:append_y_, K), Symbol(:append_visits_, K))
PSE.inputs_(::AppendAdversarialProbe) = NamedTuple()
function PSE.outputs_(model::AppendAdversarialProbe{K}) where {K}
    return NamedTuple{_append_probe_names(K)}((zero(model.gain), zero(model.gain), 0))
end
@generated function PSE.run!(model::AppendAdversarialProbe{K}, status, environment,
    constants, context) where {K}
    x, y, visits = QuoteNode.(_append_probe_names(K))
    return quote
        setproperty!(status, $x, getproperty(status, $x) + model.gain)
        setproperty!(status, $y, getproperty(status, $y) + 2 * model.gain)
        setproperty!(status, $visits, getproperty(status, $visits) + 1)
        nothing
    end
end
region_effects(::Type{<:AppendAdversarialProbe}) = :local_ports

function _append_probe_status(groups; alias_groups=())
    names = Tuple(name for K in 1:groups for name in _append_probe_names(K))
    references = Ref[]
    for K in 1:groups
        x = Ref(0.0)
        append!(references, (x, K in alias_groups ? x : Ref(0.0), Ref(0)))
    end
    return PSE.Status(NamedTuple{names}(Tuple(references)))
end

function _append_probe_fixture(; groups=1, alias_groups=())
    objects = [PSE.Object(id; kind=:append_probe,
        status=_append_probe_status(groups; alias_groups)) for id in 1:2]
    applications = Tuple(PSE.ModelSpec(AppendAdversarialProbe{K,Float64}(1.0);
        name=Symbol(:append_, K), on=PSE.Many(kind=:append_probe), every=Hour(1))
        for K in 1:groups)
    return PSE.CompositeModel(objects...; applications, environment=(duration=Hour(1),))
end

function _append_adversarial_program(model)
    simulation = PSE.run!(model; steps=0, outputs=:all)
    return compile_regions(simulation; regions=true, resolved_calls=false,
        compact=true, state_strategy=:references, refresh_strategy=:append)
end

function _append_adversarial_batches(program)
    return [batch for batch in program.simulation.execution_plan.batches
        if batch isa RegionColumnBatch]
end

function _append_adversarial_advance!(reference, program)
    PSE.continue!(reference; steps=1)
    advance_regions!(program; steps=1)
    @test isequal(GP.fingerprint(program.simulation), GP.fingerprint(reference))
    return nothing
end

function _append_rejected_storage(batch)
    return (ids=batch.targets.object_ids, id_values=copy(batch.targets.object_ids),
        columns=values(batch.state.data.references),
        column_values=map(copy, values(batch.state.data.references)),
        state=batch.state, nrows=batch.state.data.nrows)
end

function _test_append_rejected_storage(snapshot)
    @test snapshot.ids == snapshot.id_values
    @test snapshot.state.data.nrows == snapshot.nrows
    for (column, references) in zip(snapshot.columns, snapshot.column_values)
        @test length(column) == length(references)
        @test all(a === b for (a, b) in zip(column, references))
    end
    return nothing
end

function _append_override_fixture()
    base = AppendAdversarialProbe{1,Float64}(1.0)
    replacements = Dict{PSE.ObjectId,typeof(base)}(PSE.ObjectId(1) => base)
    models = PSE.ObjectModelOverrides(base, replacements)
    model = PSE.CompositeModel((PSE.Object(id; kind=:append_probe,
            status=_append_probe_status(1)) for id in 1:2)...;
        applications=(PSE.ModelSpec(models; name=:append_1,
            on=PSE.Many(kind=:append_probe), every=Hour(1)),),
        environment=(duration=Hour(1),))
    return (; model, replacements)
end

function _append_mixed_environment_fixture()
    backend = GP.CompletionSpatialBackend()
    objects = [PSE.Object(id; kind=:append_probe, geometry=(cell=:sun,),
        status=_append_probe_status(1)) for id in (:row_1, :row_2)]
    model = PSE.CompositeModel(objects...; applications=(
        PSE.ModelSpec(AppendAdversarialProbe{1,Float64}(1.0);
            name=:append_1, on=PSE.Many(kind=:append_probe), every=Hour(1)),
        PSE.ModelSpec(GP.CompletionSpatialProbe(); name=:spatial_probe,
            on=PSE.Many(kind=:append_probe), every=Hour(1),
            environment=PSE.Environment(provider=:completion_spatial)),
    ), environment=backend)
    return (; model, backend)
end

"""Independent small checks for append safety; no performance samples run here."""
function append_adversarial_checks()
    reports = NamedTuple[]
    @testset "Append-only regions reject unsafe transitions transactionally" begin
        # The first group can extend, while a later group splits its old shared
        # x/y pointer array. A rejected global stage must not extend the first
        # group's old arrays before rebuilding the current execution owners.
        for groups in (1, 2)
            aliases = (groups,)
            reference = PSE.run!(_append_probe_fixture(; groups, alias_groups=aliases);
                steps=0, outputs=:all)
            program = _append_adversarial_program(
                _append_probe_fixture(; groups, alias_groups=aliases))
            _append_adversarial_advance!(reference, program)
            old_batches = _append_adversarial_batches(program)
            @test length(old_batches) == groups
            snapshots = _append_rejected_storage.(old_batches)
            for scene in (reference.model, program.simulation.model)
                PSE.register_object!(scene, PSE.Object(3; kind=:append_probe,
                    status=_append_probe_status(groups)))
            end
            _append_adversarial_advance!(reference, program)
            foreach(_test_append_rejected_storage, snapshots)
            @test PSE.model_status(program.simulation.model, 3).append_x_1 == 1.0
            @test PSE.model_status(program.simulation.model, 3).append_y_1 == 2.0
            push!(reports, (case=groups == 1 ? :alias_split : :late_group_rejection,
                passed=true))
        end

        # Same concrete model type with different parameters must not silently
        # reuse a SharedColumnModel for a newborn object. The dictionary is the
        # same authored object-override map retained in the compiled plan.
        fixture, control = _append_override_fixture(), _append_override_fixture()
        reference = PSE.run!(control.model; steps=0, outputs=:all)
        program = _append_adversarial_program(fixture.model)
        _append_adversarial_advance!(reference, program)
        old_batch = only(_append_adversarial_batches(program))
        @test old_batch.kernel.models isa GP.SharedColumnModel
        snapshot = _append_rejected_storage(old_batch)
        for scene in (fixture, control)
            scene.replacements[PSE.ObjectId(3)] = AppendAdversarialProbe{1,Float64}(4.0)
            PSE.register_object!(scene.model, PSE.Object(3; kind=:append_probe,
                status=_append_probe_status(1)))
        end
        _append_adversarial_advance!(reference, program)
        _test_append_rejected_storage(snapshot)
        @test PSE.model_status(fixture.model, 3).append_x_1 == 4.0
        @test PSE.model_status(fixture.model, 3).append_y_1 == 8.0
        PSE.continue!(reference; steps=1)
        PSE.continue!(program.simulation; steps=1)
        @test isequal(GP.fingerprint(program.simulation), GP.fingerprint(reference))
        push!(reports, (case=:same_type_override, passed=true))

        # Explicit numeric IDs may insert before the current first row. The
        # append strategy must preserve the ordinary sorted target order.
        reference = PSE.run!(_append_probe_fixture(); steps=0, outputs=:all)
        program = _append_adversarial_program(_append_probe_fixture())
        _append_adversarial_advance!(reference, program)
        snapshot = _append_rejected_storage(only(_append_adversarial_batches(program)))
        for scene in (reference.model, program.simulation.model)
            PSE.register_object!(scene, PSE.Object(0; kind=:append_probe,
                status=_append_probe_status(1)))
        end
        _append_adversarial_advance!(reference, program)
        _test_append_rejected_storage(snapshot)
        batch = only(_append_adversarial_batches(program))
        @test batch.targets.object_ids == PSE.ObjectId.([0, 1, 2])
        push!(reports, (case=:nonmonotonic_numeric_ids, passed=true))

        # A coalesced event may still be a structural addition while an old
        # object's spatial binding changes. The actual sampled old-row value
        # is asserted independently of comparison with the ordinary executor.
        fixture, control = _append_mixed_environment_fixture(),
            _append_mixed_environment_fixture()
        reference = PSE.run!(control.model; steps=0, outputs=:all)
        program = _append_adversarial_program(fixture.model)
        _append_adversarial_advance!(reference, program)
        for scene in (fixture.model, control.model)
            PSE.register_object!(scene, PSE.Object(:row_3; kind=:append_probe,
                geometry=(cell=:sun,), status=_append_probe_status(1)))
            PSE.move_object!(scene, :row_1, (cell=:shade,))
        end
        _append_adversarial_advance!(reference, program)
        @test PSE.model_status(fixture.model, :row_1).seen == 20.0
        @test PSE.model_status(control.model, :row_1).seen == 20.0
        @test fixture.backend.samples == control.backend.samples
        push!(reports, (case=:addition_plus_existing_spatial_move, passed=true))
    end
    return (; cases=length(reports), reports)
end
