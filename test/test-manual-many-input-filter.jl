using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "manual_many_filter_source" verbose = false
PlantSimEngine.@process "manual_many_filter_controller" verbose = false
PlantSimEngine.@process "manual_many_filter_reader" verbose = false
PlantSimEngine.@process "manual_many_filter_unrelated_writer" verbose = false

struct ManualManyFilterSource <: AbstractManual_Many_Filter_SourceModel end
struct ManualManyFilterController <: AbstractManual_Many_Filter_ControllerModel end
struct ManualManyFilterReader <: AbstractManual_Many_Filter_ReaderModel end
struct ManualManyFilterUnrelatedWriter <:
       AbstractManual_Many_Filter_Unrelated_WriterModel end

PlantSimEngine.inputs_(::ManualManyFilterSource) = NamedTuple()
PlantSimEngine.outputs_(::ManualManyFilterSource) = (potential=-1.0, source_calls=0)

function PlantSimEngine.run!(::ManualManyFilterSource, status, environment, constants, context)
    status.potential -= 1.0
    status.source_calls += 1
    return nothing
end

PlantSimEngine.inputs_(::ManualManyFilterController) = NamedTuple()
PlantSimEngine.outputs_(::ManualManyFilterController) = (controller_calls=0,)

function PlantSimEngine.run!(::ManualManyFilterController, status, environment, constants, context)
    run_call!(context, :source; publish=true)
    status.controller_calls += 1
    return nothing
end

PlantSimEngine.inputs_(::ManualManyFilterReader) = (
    previous_potentials=Required(AbstractVector{<:Real}),
)
PlantSimEngine.outputs_(::ManualManyFilterReader) = (
    observed_count=0,
    observed_potential=0.0,
)

function PlantSimEngine.run!(::ManualManyFilterReader, status, environment, constants, context)
    status.observed_count = length(status.previous_potentials)
    status.observed_potential = sum(status.previous_potentials; init=0.0)
    return nothing
end

PlantSimEngine.inputs_(::ManualManyFilterUnrelatedWriter) = NamedTuple()
PlantSimEngine.outputs_(::ManualManyFilterUnrelatedWriter) = NamedTuple()

function PlantSimEngine.run!(::ManualManyFilterUnrelatedWriter, status, environment, constants, context)
    targets = output_targets(context, :markers)
    assign_outputs!(targets, collect(object_ids(targets)),
        (marker_value=fill(42.0, length(targets)),))
    return nothing
end

function manual_many_filter_scenario(; distributed_output)
    applications = (
        ModelSpec(ManualManyFilterReader(); name=:lagged_reader, on=One(scale=:Scene),
            inputs=(PreviousTimeStep(:previous_potentials) => Many(
                scale=:SoilLayer, name=(:soil_layer_1,), within=Subtree(),
                application=:manual_source, var=:potential,
            ),)),
        ModelSpec(ManualManyFilterController(); name=:controller, on=One(scale=:Scene),
            calls=(source=Many(scale=:SoilLayer, within=Subtree(),
                application=:manual_source),)),
        ModelSpec(ManualManyFilterSource(); name=:manual_source, on=Many(scale=:SoilLayer)),
    )
    unrelated = distributed_output ? (
        ModelSpec(ManualManyFilterUnrelatedWriter(); name=:unrelated_writer,
            on=One(scale=:Scene),
            outputs_to=(markers=OutputTo(Many(scale=:Marker, within=Subtree());
                vars=(marker_value=Default(0.0),)),)),
    ) : ()
    return CompositeModel(
        Object(:scene; scale=:Scene, status=Status(previous_potentials=[-1.0])),
        Object(:soil_layer_1; scale=:SoilLayer, name=:soil_layer_1, parent=:scene),
        Object(:marker; scale=:Marker, parent=:scene);
        applications=(applications..., unrelated...),
        environment=(duration=Hour(1),),
    )
end

@testset "unrelated distributed output preserves a manual producer in lagged Many" begin
    # Manual callees are intentionally absent from scheduled canonical writer
    # ownership. Enabling distributed output elsewhere must not make that
    # ownership index an exhaustive inventory of valid input producers.
    for distributed_output in (false, true)
        @testset "distributed_output=$distributed_output" begin
            model = manual_many_filter_scenario(; distributed_output)
            binding = only(row for row in Diagnostics.explain_bindings(model)
                if row.application_id == :lagged_reader)
            @test binding.source_ids == [:soil_layer_1]
            @test binding.source_application_ids == [:manual_source]
            @test binding.policy isa PreviousTimeStep

            schedule = only(row for row in Diagnostics.explain_schedule(model)
                if row.application_id == :manual_source)
            @test schedule.manual_call_only

            simulation = run!(model; steps=1, outputs=:all)
            scene = model_status(model, :scene)
            soil = model_status(model, :soil_layer_1)
            @test scene.observed_count == 1
            @test scene.observed_potential == -1.0
            @test scene.controller_calls == 1
            @test soil.source_calls == 1
            @test soil.potential == -2.0

            continue!(simulation; steps=1)
            @test scene.observed_count == 1
            @test scene.observed_potential == -2.0
            @test scene.controller_calls == 2
            @test soil.source_calls == 2
            @test soil.potential == -3.0
            if distributed_output
                @test model_status(model, :marker).marker_value == 42.0
            end
        end
    end
end

PlantSimEngine.@process "private_many_filter_source" verbose = false
PlantSimEngine.@process "private_many_filter_canonical_source" verbose = false
PlantSimEngine.@process "private_many_filter_reader" verbose = false

struct PrivateManyFilterSource <: AbstractPrivate_Many_Filter_SourceModel end
struct PrivateManyFilterCanonicalSource <:
       AbstractPrivate_Many_Filter_Canonical_SourceModel end
struct PrivateManyFilterReader{S} <: AbstractPrivate_Many_Filter_ReaderModel
    selector::S
end

PlantSimEngine.inputs_(::PrivateManyFilterSource) = NamedTuple()
PlantSimEngine.outputs_(::PrivateManyFilterSource) = (potential=-1.0,)
function PlantSimEngine.run!(::PrivateManyFilterSource, status, environment, constants, context)
    status.potential -= 1.0
    return nothing
end

PlantSimEngine.inputs_(::PrivateManyFilterCanonicalSource) = NamedTuple()
PlantSimEngine.outputs_(::PrivateManyFilterCanonicalSource) = (potential=1000.0,)
function PlantSimEngine.run!(::PrivateManyFilterCanonicalSource, status, environment, constants, context)
    status.potential = 1000.0
    return nothing
end

PlantSimEngine.inputs_(::PrivateManyFilterReader) = (
    previous_private_potentials=Required(AbstractVector{<:Real}),
)
PlantSimEngine.outputs_(::PrivateManyFilterReader) = (observed_private_potential=0.0,)
PlantSimEngine.dep(model::PrivateManyFilterReader) = (
    previous_private_potentials=Input(model.selector),
)
function PlantSimEngine.run!(::PrivateManyFilterReader, status, environment, constants, context)
    status.observed_private_potential = sum(status.previous_private_potentials; init=0.0)
    return nothing
end

@testset "lagged Many selects a private local output beside another canonical owner" begin
    for filter_kind in (:application, :process)
        @testset "$filter_kind filter" begin
            # Process selection belongs to the model's Input declaration;
            # explicit scenario bindings use canonical application names.
            source_filter = filter_kind == :application ?
                (application=:private_source,) : (process=:private_many_filter_source,)
            selector = Many(;
                scale=:Leaf, within=Subtree(), var=:potential,
                policy=PreviousTimeStep(:previous_private_potentials),
                source_filter...,
            )
            model = CompositeModel(
                Object(:scene; scale=:Scene,
                    status=Status(previous_private_potentials=[-1.0])),
                Object(:private_leaf; scale=:Leaf, name=:private_leaf, parent=:scene),
                Object(:canonical_only_leaf; scale=:Leaf, parent=:scene),
                Object(:marker; scale=:Marker, parent=:scene);
                applications=(
                    ModelSpec(PrivateManyFilterReader(selector);
                        name=:private_reader, on=One(scale=:Scene)),
                    ModelSpec(PrivateManyFilterSource(); name=:private_source,
                        on=One(name=:private_leaf), output_routing=(potential=:stream_only,)),
                    ModelSpec(PrivateManyFilterCanonicalSource();
                        name=:canonical_source, on=Many(scale=:Leaf)),
                    ModelSpec(ManualManyFilterUnrelatedWriter(); name=:private_case_distributor,
                        on=One(scale=:Scene),
                        outputs_to=(markers=OutputTo(Many(scale=:Marker, within=Subtree());
                            vars=(marker_value=Default(0.0),)),)),
                ),
                environment=(duration=Hour(1),),
            )
            binding = only(row for row in Diagnostics.explain_bindings(model)
                if row.application_id == :private_reader)
            @test binding.source_ids == [:private_leaf]
            @test binding.source_application_ids == [:private_source]

            simulation = run!(model; steps=1, outputs=:all)
            @test model_status(model, :scene).observed_private_potential == -1.0
            continue!(simulation; steps=1)
            @test model_status(model, :scene).observed_private_potential == -2.0
        end
    end
end
