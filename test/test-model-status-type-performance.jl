using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "status_type_performance_kernel" verbose = false

struct StatusTypePerformanceKernelModel <:
       AbstractStatus_Type_Performance_KernelModel end

PlantSimEngine.inputs_(::StatusTypePerformanceKernelModel) = (
    gain=Default(1.0),
)
PlantSimEngine.outputs_(::StatusTypePerformanceKernelModel) = (state=0.0,)

function PlantSimEngine.run!(
    ::StatusTypePerformanceKernelModel,
    status,
    environment,
    constants,
    context,
)
    status.state += status.gain
    return nothing
end

struct StatusTypePerformanceTransform
    calls::Base.RefValue{Int}
end

function (transform::StatusTypePerformanceTransform)(variable, value)
    transform.calls[] += 1
    return value
end

function _status_type_performance_model(
    object_count;
    type_promotion=nothing,
    status_transform=nothing,
)
    objects = [
        Object(
            Symbol(:leaf_, index);
            scale=:Leaf,
            status=Status(gain=1.0),
        )
        for index in 1:object_count
    ]
    return CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                StatusTypePerformanceKernelModel();
                name=:status_type_performance_kernel,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=type_promotion,
        status_transform=status_transform,
    )
end

# Keep the complete measured path behind a specialization boundary. Both
# simulation types are warmed before `@allocated` is used, so compilation and
# test machinery are excluded from the measurement.
@noinline function _status_type_performance_advance!(
    simulation::S,
    steps::Int,
) where {S}
    for _ in 1:steps
        step!(simulation)
    end
    return nothing
end

@noinline function _status_type_performance_allocations(
    simulation::S,
    steps::Int,
) where {S}
    return @allocated _status_type_performance_advance!(simulation, steps)
end

@testset "status conversion policy stays outside the hot step path" begin
    object_count = 64
    measured_steps = 16
    repetitions = 5
    transform_calls = Ref(0)
    transform = StatusTypePerformanceTransform(transform_calls)

    baseline_model = _status_type_performance_model(object_count)
    converted_model = _status_type_performance_model(
        object_count;
        type_promotion=Dict(Float64 => Float32),
        status_transform=transform,
    )

    # Compile first so policy work cannot be charged to the runtime sample.
    Advanced.refresh_bindings!(baseline_model)
    Advanced.refresh_bindings!(converted_model)
    @test transform_calls[] == 2 * object_count

    baseline = run!(baseline_model; outputs=:none)
    converted = run!(converted_model; outputs=:none)
    @test isempty(outputs(baseline))
    @test isempty(outputs(converted))
    @test final_state(baseline, :leaf_1).state isa Float64
    @test final_state(converted, :leaf_1).state isa Float32

    # Warm both concrete Simulation specializations and the allocation helper.
    _status_type_performance_advance!(baseline, 3)
    _status_type_performance_advance!(converted, 3)
    _status_type_performance_allocations(baseline, 2)
    _status_type_performance_allocations(converted, 2)

    calls_after_warmup = transform_calls[]
    @test calls_after_warmup == 2 * object_count

    # Exercise the public one-step API directly before measuring it in a loop.
    for _ in 1:8
        step!(baseline)
        step!(converted)
    end
    @test transform_calls[] == calls_after_warmup
    @test final_state(baseline, :leaf_1).state ==
          final_state(converted, :leaf_1).state

    baseline_allocations = ntuple(
        _ -> _status_type_performance_allocations(
            baseline,
            measured_steps,
        ),
        repetitions,
    )
    converted_allocations = ntuple(
        _ -> _status_type_performance_allocations(
            converted,
            measured_steps,
        ),
        repetitions,
    )

    # A relative equality is deliberate: Julia may change the scheduler's
    # absolute byte count, but an initialization-only policy must add no
    # allocation to the otherwise identical warmed runtime path.
    @test all(==(first(baseline_allocations)), baseline_allocations)
    @test all(==(first(converted_allocations)), converted_allocations)
    @test converted_allocations == baseline_allocations
    @test transform_calls[] == calls_after_warmup
    @test final_state(baseline, :leaf_1).state ==
          final_state(converted, :leaf_1).state
end
