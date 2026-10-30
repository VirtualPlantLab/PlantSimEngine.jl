module CoalescedGrowthEnvironmentChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

mutable struct CoalescedSpatialBackend <: EA.AbstractEnvironmentBackend
    samples::Vector{Tuple{PSE.ObjectId,Symbol,Float64}}
end
CoalescedSpatialBackend() = CoalescedSpatialBackend(Tuple{PSE.ObjectId,Symbol,Float64}[])
EA.base_step_seconds(::CoalescedSpatialBackend) = 3600.0
EA.get_nsteps(::CoalescedSpatialBackend) = 8
EA.environment_variables(::CoalescedSpatialBackend) = Set((:T,))
function EA.bind_environment(::CoalescedSpatialBackend, object::PSE.Object, context, config)
    return (cell=PSE.geometry(object).cell, object_id=context.object_id)
end
function EA.sample(backend::CoalescedSpatialBackend, handle, variable::Symbol, time)
    variable === :T || error("Unexpected environment variable $(variable)")
    value = handle.cell === :sun ? 10.0 : 20.0
    push!(backend.samples, (handle.object_id, handle.cell, value))
    return value
end

PSE.@process "coalesced_spatial_probe" verbose=false
struct CoalescedSpatialProbe <: AbstractCoalesced_Spatial_ProbeModel end
PSE.inputs_(::CoalescedSpatialProbe) = NamedTuple()
PSE.outputs_(::CoalescedSpatialProbe) = (seen=0.0, visits=0)
PSE.environment_inputs_(::CoalescedSpatialProbe) = (T=0.0,)
function PSE.run!(::CoalescedSpatialProbe, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    return nothing
end

PSE.@process "coalesced_call_owner" verbose=false
struct CoalescedCallOwner <: AbstractCoalesced_Call_OwnerModel end
PSE.inputs_(::CoalescedCallOwner) = NamedTuple()
PSE.outputs_(::CoalescedCallOwner) = (observed=0.0,)
function PSE.run!(::CoalescedCallOwner, status, environment, constants, context)
    target = only(PSE.run_call!(context, :probe; publish=true))
    status.observed = target.status.seen
    return nothing
end

function fixture(ids; calls=false)
    backend = CoalescedSpatialBackend()
    objects = PSE.Object[PSE.Object(id; kind=:coalesced_unit, geometry=(cell=:sun,))
        for id in ids[1:2]]
    applications = PSE.ModelSpec[PSE.ModelSpec(CoalescedSpatialProbe(); name=:probe,
        on=PSE.Many(kind=:coalesced_unit), every=Hour(1))]
    if calls
        push!(objects, PSE.Object(:owner; geometry=(cell=:sun,)))
        push!(applications, PSE.ModelSpec(CoalescedCallOwner(); name=:owner,
            on=PSE.One(id=:owner), every=Hour(1),
            calls=(probe=PSE.One(id=ids[1], within=PSE.SceneScope(),
                application=:probe),)))
    end
    return (; model=PSE.CompositeModel(objects...; applications, environment=backend), backend)
end

function invalidate!(model, object_id, mode)
    if mode === :movement
        PSE.move_object!(model, object_id, (cell=:shade,))
    else
        PSE.update_geometry!(only(PSE.model_objects(model; id=object_id)), (cell=:shade,))
        mode === :targeted_dirty ? PSE.mark_environment_binding_dirty!(model, object_id) :
            PSE.mark_environment_binding_dirty!(model)
    end
    return nothing
end

@testset "Growth and existing spatial invalidation coalesce safely" begin
    for ids in ((1, 2, 3), (:old_a, :old_b, :new_c)),
        mode in (:movement, :targeted_dirty, :full_dirty),
        addition_first in (false, true), outputs in (:none, :all)
        case = fixture(ids)
        simulation = PSE.run!(case.model; steps=1, outputs)
        @test PSE.model_status(case.model, ids[1]).seen == 10.0
        stable_status = PSE.model_status(case.model, ids[1])
        untouched_binding = simulation.environment_bindings.by_target[(:probe, PSE.ObjectId(ids[2]))]
        add! = () -> PSE.register_object!(case.model, PSE.Object(ids[3];
            kind=:coalesced_unit, geometry=(cell=:sun,)))
        addition_first && add!()
        invalidate!(case.model, ids[1], mode)
        addition_first || add!()
        @test PSE.lifecycle_delta(case.model).structural_kind === :addition
        PSE.continue!(simulation; steps=1)
        @test stable_status === PSE.model_status(case.model, ids[1])
        @test stable_status.seen == 20.0
        @test PSE.model_status(case.model, ids[2]).seen == 10.0
        @test PSE.model_status(case.model, ids[3]).seen == 10.0
        @test (PSE.ObjectId(ids[1]), :shade, 20.0) in case.backend.samples
        if mode !== :full_dirty
            @test simulation.environment_bindings.by_target[(:probe, PSE.ObjectId(ids[2]))] ===
                untouched_binding
        end
        target = only(target for batch in simulation.execution_plan.batches
            for target in batch.targets if target.object_id == PSE.ObjectId(ids[1]))
        current_binding = simulation.environment_bindings.by_target[(:probe, PSE.ObjectId(ids[1]))]
        @test current_binding.handle.cell === :shade
        @test target.environment_binding === current_binding
    end

    # The unchanged controller's tracked CallTargets must pick up the current
    # spatial binding too, even though only the callee moved during growth.
    for mode in (:movement, :targeted_dirty, :full_dirty)
        ids = (:call_old_a, :call_old_b, :call_new_c)
        case = fixture(ids; calls=true)
        simulation = PSE.run!(case.model; steps=1, outputs=:all)
        @test PSE.model_status(case.model, :owner).observed == 10.0
        PSE.register_object!(case.model, PSE.Object(ids[3];
            kind=:coalesced_unit, geometry=(cell=:sun,)))
        invalidate!(case.model, ids[1], mode)
        PSE.continue!(simulation; steps=1)
        @test PSE.model_status(case.model, :owner).observed == 20.0
        @test PSE.model_status(case.model, ids[1]).seen == 20.0
        @test PSE.model_status(case.model, ids[1]).visits == 2
        # The same eager singular cache must refresh for a later environment-
        # only event, with no structural compilation to replace its owner.
        if mode === :movement
            PSE.move_object!(case.model, ids[1], (cell=:sun,))
        else
            PSE.update_geometry!(only(PSE.model_objects(case.model; id=ids[1])), (cell=:sun,))
            mode === :targeted_dirty ? PSE.mark_environment_binding_dirty!(case.model, ids[1]) :
                PSE.mark_environment_binding_dirty!(case.model)
        end
        PSE.continue!(simulation; steps=1)
        @test PSE.model_status(case.model, :owner).observed == 10.0
        @test PSE.model_status(case.model, ids[1]).seen == 10.0
        @test PSE.model_status(case.model, ids[1]).visits == 3
    end

    # A newborn-only event must keep the original ID-set identity so the
    # existing pure-addition fast path remains available.
    case = fixture((1, 2, 3))
    simulation = PSE.run!(case.model; steps=1, outputs=:none)
    PSE.register_object!(case.model, PSE.Object(3;
        kind=:coalesced_unit, geometry=(cell=:sun,)))
    PSE.continue!(simulation; steps=1)
    compiled = simulation.compiled
    apps, targets = PSE._execution_refresh_with_environment_dirty_targets(compiled,
        compiled.changed_execution_application_ids, compiled.changed_execution_target_ids,
        (PSE.ObjectId(3),))
    @test apps === compiled.changed_execution_application_ids
    @test targets === compiled.changed_execution_target_ids
end

end
