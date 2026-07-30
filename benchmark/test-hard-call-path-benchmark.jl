using PlantSimEngine

PlantSimEngine.@process "benchmark_call_source" verbose = false
PlantSimEngine.@process "benchmark_call_controller" verbose = false
PlantSimEngine.@process "benchmark_unrelated_work" verbose = false

struct BenchmarkCallSourceModel <: AbstractBenchmark_Call_SourceModel end
struct BenchmarkCallControllerModel <: AbstractBenchmark_Call_ControllerModel end
struct BenchmarkUnrelatedWorkModel <: AbstractBenchmark_Unrelated_WorkModel end

PlantSimEngine.inputs_(::BenchmarkCallSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkCallSourceModel) = (signal=0,)

function PlantSimEngine.run!(
    ::BenchmarkCallSourceModel,
    status,
    environment,
    constants,
    context,
)
    status.signal += 1
    return nothing
end

PlantSimEngine.inputs_(::BenchmarkCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkCallControllerModel) = (called_signal=0,)

function PlantSimEngine.run!(
    ::BenchmarkCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    target = only(run_call!(context, :source; publish=false))
    status.called_signal = target.status.signal
    return nothing
end

PlantSimEngine.inputs_(::BenchmarkUnrelatedWorkModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkUnrelatedWorkModel) = (work=0,)

function PlantSimEngine.run!(
    ::BenchmarkUnrelatedWorkModel,
    status,
    environment,
    constants,
    context,
)
    status.work += 1
    return nothing
end

function setup_hard_call_path_benchmark(;
    nobjects=1000,
    usage=:sparse,
    steps=100,
)
    usage in (:zero, :sparse, :dense) || error(
        "Unsupported hard-call benchmark usage `$(usage)`. Use `:zero`, ",
        "`:sparse`, or `:dense`.",
    )
    objects = Any[PlantSimEngine.Object(:scene; scale=:Scene)]
    append!(
        objects,
        (
            PlantSimEngine.Object(
                Symbol(:leaf_, index);
                scale=:Leaf,
                name=Symbol(:leaf_, index),
                parent=:scene,
            )
            for index in 1:nobjects
        ),
    )
    source = ModelSpec(
        BenchmarkCallSourceModel();
        name=:source,
        on=Many(scale=:Leaf),
    )
    unrelated = ModelSpec(
        BenchmarkUnrelatedWorkModel();
        name=:unrelated,
        on=Many(scale=:Leaf),
    )
    applications = if usage == :zero
        (source, unrelated)
    else
        caller_selector =
            usage == :sparse ?
            One(name=:leaf_1) :
            Many(scale=:Leaf)
        caller = ModelSpec(
            BenchmarkCallControllerModel();
            name=:controller,
            on=caller_selector,
            calls=(
                :source =>
                    One(within=Self(), application=:source),
            ),
        )
        (source, caller, unrelated)
    end
    return CompositeModel(objects...; applications=applications), Int(steps)
end

function benchmark_hard_call_path(model, steps)
    return run!(model; steps=steps, outputs=:none)
end

function hard_call_path_summary(model)
    rows = PlantSimEngine.Diagnostics.explain_execution_plan(model)
    return (
        no_call_targets=sum((
            row.batch_size for row in rows
            if row.call_capability == :no_calls
        ); init=0),
        call_capable_targets=sum((
            row.batch_size for row in rows
            if row.call_capability == :compiled_calls
        ); init=0),
        unrelated_no_call_targets=sum((
            row.batch_size for row in rows
            if row.application_id == :unrelated &&
               row.call_capability == :no_calls
        ); init=0),
    )
end

function setup_lifecycle_hard_call_benchmark(;
    nobjects=1000,
    usage=:zero,
)
    model, _ = setup_hard_call_path_benchmark(;
        nobjects=nobjects,
        usage=usage,
        steps=1,
    )
    simulation = run!(
        model;
        steps=1,
        outputs=:none,
        performance=true,
    )
    return simulation, nobjects + 1
end

function benchmark_lifecycle_event(simulation, new_index)
    new_id = Symbol(:leaf_, new_index)
    register_object!(
        simulation.model,
        PlantSimEngine.Object(
            new_id;
            scale=:Leaf,
            name=new_id,
            parent=:scene,
        ),
    )
    continue!(simulation)
    return simulation
end
