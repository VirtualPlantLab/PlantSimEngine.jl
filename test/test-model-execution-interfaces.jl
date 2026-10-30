module ExecutionInterfaceChecks

using Test, Dates, PlantSimEngine
const PSE = PlantSimEngine

PSE.@process "execution_interface_probe" verbose=false
struct Probe{C} <: AbstractExecution_Interface_ProbeModel
    capture::C
end
PSE.inputs_(::Probe) = (x=Default(0.0),)
PSE.outputs_(::Probe) = (result=0.0,)

# A distinct helper with the supported concrete Status argument is deliberate.
typed_status_helper(status::Status) = status.x + status.extra
function PSE.run!(model::Probe, status::Status, environment, constants, context)
    status.result = typed_status_helper(status)
    model.capture[] = (
        status_type=typeof(status), context_type=typeof(context),
        local_names=keys(getfield(status, :vars)),
        visible_names=keys(status), snapshot=NamedTuple(status),
        extra_reference=PSE.refvalue(status, :extra),
        status_identity=PSE._status_identity(status),
        element_types=eltype(status), reference_values=PSE.refvalues(status),
    )
    return nothing
end

function fixture(; padding=0, application=:probe)
    capture = Ref{Any}()
    external = [3.0]
    names = (:x, :extra, Tuple(Symbol(:padding_, i) for i in 1:padding)...)
    references = (Ref(2.0), Ref(external, 1), (Ref(0.0) for _ in 1:padding)...)
    original = Status(NamedTuple{names}(references))
    model = CompositeModel(
        Object(:leaf; scale=:Leaf, status=original);
        applications=(ModelSpec(Probe(capture); name=application, on=Many(scale=:Leaf)),),
        environment=(duration=Hour(1),),
    )
    return (; model, capture, external)
end

function prepared(data; narrow_status, local_context)
    return PSE._with_execution_policy(; narrow_status, local_context) do
        run!(data.model; steps=0, outputs=:all)
    end
end

@testset "local execution interfaces preserve live Status behavior" begin
    for narrow_status in (false, true), local_context in (false, true)
        data = fixture(padding=4)
        sim = prepared(data; narrow_status, local_context)
        # Preparation captures the policy: both continuation and refresh below
        # happen after its task-local scope has ended.
        step!(sim)
        observed = data.capture[]
        @test final_state(sim, :leaf).result == 5.0
        @test observed.snapshot.extra == 3.0
        @test Set(observed.visible_names) ==
              Set((:x, :extra, :padding_1, :padding_2, :padding_3, :padding_4, :result))
        canonical = model_status(data.model, :leaf)
        @test observed.extra_reference === PSE.refvalue(canonical, :extra)
        @test observed.status_identity === PSE._status_identity(canonical)
        @test observed.element_types == eltype(canonical)
        @test observed.reference_values == PSE.refvalues(canonical)
        @test observed.local_names == (narrow_status ? (:x, :result) : keys(canonical))
        @test (fieldtype(observed.context_type, :compiled) === Any) == local_context
        data.external[1] = 8.0
        step!(sim)
        @test final_state(sim, :leaf).result == 10.0
        register_object!(data.model,
            Object(:newborn; scale=:Leaf, status=Status(x=1.0, extra=4.0)))
        step!(sim)
        @test final_state(sim, :newborn).result == 5.0
        summary = PSE._execution_policy_summary(sim)
        @test summary.policy.narrow_status == narrow_status
        @test summary.policy.local_context == local_context
        @test summary.narrow_statuses == (narrow_status ? 2 : 0)
        @test summary.local_contexts == (local_context ? 2 : 0)
    end
end

@testset "local interface shapes exclude unrelated status and application names" begin
    for narrow_status in (false, true), local_context in (false, true)
        a, b = fixture(), fixture(padding=8, application=:renamed_probe)
        sim_a = prepared(a; narrow_status, local_context)
        sim_b = prepared(b; narrow_status, local_context)
        step!(sim_a)
        step!(sim_b)
        @test (a.capture[].status_type === b.capture[].status_type) == narrow_status
        @test (a.capture[].context_type === b.capture[].context_type) == local_context
        @test final_state(sim_a, :leaf).result == final_state(sim_b, :leaf).result
    end
end

@testset "narrow Status keeps positional and symbolic writes on original cells" begin
    data = fixture(padding=1)
    sim = prepared(data; narrow_status=true, local_context=true)
    target = first(first(first(sim.execution_plan.groups).batches).targets)
    local_status = PSE._execution_kernel_status(target)
    canonical = target.status
    @test local_status isa Status
    @test keys(local_status) == keys(canonical)
    @test values(local_status) == values(canonical)
    @test Tuple(local_status) == Tuple(canonical)
    @test length(local_status) == length(canonical)
    @test collect(local_status) == collect(canonical)
    local_status.extra = 9.0
    @test data.external[1] == 9.0
    local_status[2] = 11.0
    @test data.external[1] == 11.0
    local_status[:x] = 7.0
    @test canonical.x == 7.0
    @test PSE.refvalue(local_status, :x) === PSE.refvalue(canonical, :x)
end

end
