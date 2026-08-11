using Dates
using PlantSimEngine

PlantSimEngine.@process "benchmark_call_source" verbose = false
PlantSimEngine.@process "benchmark_call_controller" verbose = false
PlantSimEngine.@process "benchmark_bulk_call_controller" verbose = false
PlantSimEngine.@process "benchmark_sampled_environment_source" verbose = false
PlantSimEngine.@process "benchmark_sampled_environment_controller" verbose = false
PlantSimEngine.@process "benchmark_unrelated_work" verbose = false

struct BenchmarkCallSourceModel <: AbstractBenchmark_Call_SourceModel end
struct BenchmarkAlternateCallSourceModel <: AbstractBenchmark_Call_SourceModel end
struct BenchmarkCallControllerModel <: AbstractBenchmark_Call_ControllerModel end
struct BenchmarkBulkCallControllerModel{P,C} <:
       AbstractBenchmark_Bulk_Call_ControllerModel
    repeats::Int
    publish::P
    capture_context::C
end
struct BenchmarkSampledEnvironmentSourceModel <:
       AbstractBenchmark_Sampled_Environment_SourceModel end
struct BenchmarkSampledEnvironmentControllerModel{E} <:
       AbstractBenchmark_Sampled_Environment_ControllerModel
    sampled_environment::E
end
struct BenchmarkUnrelatedWorkModel <: AbstractBenchmark_Unrelated_WorkModel end

const BENCHMARK_BULK_CALL_CONTEXT = Ref{Any}()

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

PlantSimEngine.inputs_(::BenchmarkSampledEnvironmentSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkSampledEnvironmentSourceModel) =
    (temperature_seen=0.0,)
PlantSimEngine.environment_inputs_(::BenchmarkSampledEnvironmentSourceModel) =
    (T=Required(Float64),)

function PlantSimEngine.run!(
    ::BenchmarkSampledEnvironmentSourceModel,
    status,
    environment,
    constants,
    context,
)
    status.temperature_seen = environment.T
    return nothing
end

PlantSimEngine.inputs_(::BenchmarkSampledEnvironmentControllerModel) =
    NamedTuple()
PlantSimEngine.outputs_(::BenchmarkSampledEnvironmentControllerModel) =
    (executions=0,)

function PlantSimEngine.run!(
    model::BenchmarkSampledEnvironmentControllerModel,
    status,
    environment,
    constants,
    context,
)
    run_call!(
        context,
        :source;
        sampled_environment=model.sampled_environment,
        publish=false,
    )
    BENCHMARK_BULK_CALL_CONTEXT[] = context
    status.executions += 1
    return nothing
end

PlantSimEngine.inputs_(::BenchmarkAlternateCallSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkAlternateCallSourceModel) = (signal=0,)

function PlantSimEngine.run!(
    ::BenchmarkAlternateCallSourceModel,
    status,
    environment,
    constants,
    context,
)
    status.signal += 2
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

PlantSimEngine.inputs_(::BenchmarkBulkCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::BenchmarkBulkCallControllerModel) = (executions=0,)

function PlantSimEngine.run!(
    model::BenchmarkBulkCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    for _ in 1:model.repeats
        run_call!(context, :source; publish=model.publish)
    end
    model.capture_context && (BENCHMARK_BULK_CALL_CONTEXT[] = context)
    status.executions += model.repeats
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

function setup_compiled_hard_call_benchmark(;
    kind=:singular,
    target_count=1000,
    repeats=1,
    publish=false,
    steps=100,
)
    kind in (
        :singular,
        :repeated,
        :nested,
        :many,
        :heterogeneous,
        :sampled_environment,
        :published,
    ) ||
        error("Unsupported compiled hard-call benchmark kind `$(kind)`.")
    if kind == :heterogeneous
        template = CompositeModelTemplate(
            (
                ModelSpec(
                    BenchmarkCallSourceModel();
                    name=:source,
                    on=Many(scale=:Leaf),
                ),
                ModelSpec(
                    BenchmarkBulkCallControllerModel(1, false, true);
                    name=:controller,
                    on=One(scale=:Plant),
                    calls=(
                        :source => Many(
                            scale=:Leaf,
                            within=Subtree(),
                            application=:source,
                        ),
                    ),
                ),
            );
            kind=:plant,
        )
        instance = ObjectInstance(
            :benchmark_plant,
            template;
            root=PlantSimEngine.Object(
                :plant;
                scale=:Plant,
                parent=:scene,
            ),
            objects=(
                PlantSimEngine.Object(
                    :leaf_1;
                    scale=:Leaf,
                    parent=:plant,
                ),
                PlantSimEngine.Object(
                    :leaf_2;
                    scale=:Leaf,
                    parent=:plant,
                ),
            ),
            object_overrides=(
                Override(
                    object=:leaf_2,
                    application=:source,
                    model=BenchmarkAlternateCallSourceModel(),
                ),
            ),
        )
        return (
            CompositeModel(
                PlantSimEngine.Object(:scene; scale=:Scene),
                instance,
            ),
            Int(steps),
        )
    end
    if kind == :sampled_environment
        model = CompositeModel(
            PlantSimEngine.Object(:scene; scale=:Scene, name=:scene),
            PlantSimEngine.Object(
                :leaf_1;
                scale=:Leaf,
                name=:leaf_1,
                parent=:scene,
            );
            applications=(
                ModelSpec(
                    BenchmarkSampledEnvironmentSourceModel();
                    name=:source,
                    on=One(name=:leaf_1),
                ),
                ModelSpec(
                    BenchmarkSampledEnvironmentControllerModel((T=30.0,));
                    name=:controller,
                    on=One(name=:scene),
                    calls=(
                        :source => One(
                            name=:leaf_1,
                            application=:source,
                        ),
                    ),
                ),
            ),
            environment=(T=20.0, duration=Hour(1)),
        )
        return model, Int(steps)
    end
    leaf_count = kind == :many ? target_count : 1
    objects = Any[PlantSimEngine.Object(:scene; scale=:Scene, name=:scene)]
    if kind == :nested
        push!(
            objects,
            PlantSimEngine.Object(
                :middle;
                scale=:Plant,
                name=:middle,
                parent=:scene,
            ),
        )
    end
    append!(
        objects,
        (
            PlantSimEngine.Object(
                Symbol(:leaf_, index);
                scale=:Leaf,
                name=Symbol(:leaf_, index),
                parent=kind == :nested ? :middle : :scene,
            )
            for index in 1:leaf_count
        ),
    )

    source = ModelSpec(
        BenchmarkCallSourceModel();
        name=:source,
        on=Many(scale=:Leaf),
    )
    if kind == :nested
        middle = ModelSpec(
            BenchmarkBulkCallControllerModel(1, false, false);
            name=:middle,
            on=One(name=:middle),
            calls=(
                :source => One(
                    name=:leaf_1,
                    within=Subtree(),
                    application=:source,
                ),
            ),
        )
        root = ModelSpec(
            BenchmarkBulkCallControllerModel(1, false, true);
            name=:root,
            on=One(name=:scene),
            calls=(
                :source => One(
                    name=:middle,
                    within=Subtree(),
                    application=:middle,
                ),
            ),
        )
        applications = (source, middle, root)
    else
        selector = kind == :many ?
                   Many(scale=:Leaf, application=:source) :
                   One(name=:leaf_1, application=:source)
        effective_repeats = kind == :repeated ? repeats : 1
        effective_publish = kind == :published ? true : publish
        controller = ModelSpec(
            BenchmarkBulkCallControllerModel(
                effective_repeats,
                effective_publish,
                true,
            );
            name=:controller,
            on=One(name=:scene),
            calls=(:source => selector,),
        )
        applications = (source, controller)
    end
    return (
        CompositeModel(objects...; applications=applications),
        Int(steps),
    )
end

benchmark_compiled_hard_call(model, steps) =
    run!(model; steps=steps, outputs=:none)

function setup_compiled_hard_call_step(; kwargs...)
    model, _ = setup_compiled_hard_call_benchmark(; steps=1, kwargs...)
    return run!(model; steps=1, outputs=:none)
end

benchmark_compiled_hard_call_step(simulation) = step!(simulation)

function benchmark_compiled_hard_call_invocation(
    context::T;
    repeats=1,
    publish=false,
) where {T}
    for _ in 1:repeats
        run_call!(context, :source; publish=publish)
    end
    return nothing
end

function compiled_hard_call_invocation_allocations(
    context::T;
    repeats=1,
    publish=false,
) where {T}
    benchmark_compiled_hard_call_invocation(
        context;
        repeats=repeats,
        publish=publish,
    )
    return @allocated benchmark_compiled_hard_call_invocation(
        context;
        repeats=repeats,
        publish=publish,
    )
end

function benchmark_sampled_hard_call_invocation(
    context::T,
    sampled_environment,
) where {T}
    run_call!(
        context,
        :source;
        sampled_environment=sampled_environment,
        publish=false,
    )
    return nothing
end

function sampled_hard_call_invocation_allocations(
    context::T,
    sampled_environment,
) where {T}
    benchmark_sampled_hard_call_invocation(context, sampled_environment)
    return @allocated benchmark_sampled_hard_call_invocation(
        context,
        sampled_environment,
    )
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
