using Dates
using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "status_type_template_source" verbose = false
PlantSimEngine.@process "status_type_template_sum" verbose = false

struct StatusTypeTemplateSourceModel{T} <: AbstractStatus_Type_Template_SourceModel
    increment::T
end

struct StatusTypeTemplateAlternativeSourceModel{T} <:
       AbstractStatus_Type_Template_SourceModel
    increment::T
end

PlantSimEngine.outputs_(model::StatusTypeTemplateSourceModel) =
    (signal=zero(model.increment),)
PlantSimEngine.outputs_(model::StatusTypeTemplateAlternativeSourceModel) =
    (signal=zero(model.increment),)

function PlantSimEngine.run!(
    model::Union{
        StatusTypeTemplateSourceModel,
        StatusTypeTemplateAlternativeSourceModel,
    },
    status,
    environment,
    constants,
    context,
)
    status.signal += model.increment
    return nothing
end

struct StatusTypeTemplateSumModel <: AbstractStatus_Type_Template_SumModel end

PlantSimEngine.inputs_(::StatusTypeTemplateSumModel) =
    (signals=Default([0.0]),)
PlantSimEngine.outputs_(::StatusTypeTemplateSumModel) = (total=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeTemplateSumModel,
    status,
    environment,
    constants,
    context,
)
    status.total = sum(status.signals)
    return nothing
end

struct StatusTypeTemplateTransformCounter
    calls::Dict{Symbol,Int}
end

function (counter::StatusTypeTemplateTransformCounter)(variable, value)
    counter.calls[variable] = get(counter.calls, variable, 0) + 1
    return value
end

function status_type_template_binding(compiled, application_id)
    return only(
        binding for binding in compiled.input_bindings
        if binding.application_id == application_id &&
           binding.input == :signals
    )
end

@testset "type promotion crosses templates, instances, and overrides" begin
    shared_source = StatusTypeTemplateSourceModel(1.0)
    instance_source_override = StatusTypeTemplateSourceModel(2.0)
    object_source_override = StatusTypeTemplateAlternativeSourceModel(5.0)
    template = CompositeModelTemplate(
        (
            ModelSpec(
                shared_source;
                name=:source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StatusTypeTemplateSumModel();
                name=:sum,
                on=One(scale=:Plant),
                inputs=(
                    signals=Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:source,
                        var=:signal,
                    ),
                ),
            ),
        );
        kind=:plant,
    )

    plant_a = ObjectInstance(
        :plant_a,
        template;
        root=Object(
            :plant_a_root;
            scale=:Plant,
            parent=:scene,
            status=Status(baseline=10.0),
        ),
        objects=(
            Object(
                :plant_a_leaf_1;
                scale=:Leaf,
                parent=:plant_a_root,
                status=Status(initial_value=0.25),
            ),
            Object(
                :plant_a_leaf_2;
                scale=:Leaf,
                parent=:plant_a_root,
                status=Status(initial_value=0.5),
            ),
        ),
        overrides=(source=instance_source_override,),
    )
    plant_b = ObjectInstance(
        :plant_b,
        template;
        root=Object(
            :plant_b_root;
            scale=:Plant,
            parent=:scene,
            status=Status(baseline=20.0),
        ),
        objects=(
            Object(
                :plant_b_leaf_1;
                scale=:Leaf,
                parent=:plant_b_root,
                status=Status(initial_value=0.75),
            ),
            Object(
                :plant_b_leaf_2;
                scale=:Leaf,
                parent=:plant_b_root,
                status=Status(initial_value=1.0),
            ),
        ),
        object_overrides=(
            Override(
                object=:plant_b_leaf_2,
                application=:source,
                model=object_source_override,
            ),
        ),
    )

    transform_calls = Dict{Symbol,Int}()
    model = CompositeModel(
        Object(:scene; scale=:Scene, status=Status(scene_value=3.0)),
        plant_a,
        plant_b;
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
        status_transform=StatusTypeTemplateTransformCounter(transform_calls),
    )
    compiled = Advanced.refresh_bindings!(model)

    @test transform_calls == Dict(
        :scene_value => 1,
        :baseline => 2,
        :initial_value => 4,
        :signal => 4,
        :signals => 2,
        :total => 2,
    )
    materialization_calls = copy(transform_calls)
    compiled = Advanced.refresh_bindings!(model; force=true)
    @test transform_calls == materialization_calls

    @test Set(row.name for row in explain_instances(model)) ==
          Set((:plant_a, :plant_b))
    @test PlantSimEngine.model_(
        compiled.applications_by_id[:plant_a__source].spec,
    ) === instance_source_override
    @test PlantSimEngine._application_model(
        compiled.applications_by_id[:plant_b__source],
        ObjectId(:plant_b_leaf_1),
    ) === shared_source
    @test PlantSimEngine._application_model(
        compiled.applications_by_id[:plant_b__source],
        ObjectId(:plant_b_leaf_2),
    ) === object_source_override

    for object in model_objects(model)
        status = object.status
        @test status isa Status
        for variable in propertynames(status)
            value = getproperty(status, variable)
            if value isa AbstractFloat
                @test value isa Float32
            elseif value isa PlantSimEngine.RefVector
                @test eltype(value) === Float32
            end
        end
    end

    binding_a = status_type_template_binding(compiled, :plant_a__sum)
    binding_b = status_type_template_binding(compiled, :plant_b__sum)
    carrier_a = input_carrier(binding_a)
    carrier_b = input_carrier(binding_b)
    @test carrier_a isa PlantSimEngine.RefVector{Float32}
    @test carrier_b isa PlantSimEngine.RefVector{Float32}
    @test carrier_a !== carrier_b
    @test model_status(model, :plant_a_root).signals === carrier_a
    @test model_status(model, :plant_b_root).signals === carrier_b

    for (binding, carrier) in ((binding_a, carrier_a), (binding_b, carrier_b))
        @test length(binding.source_ids) == length(parent(carrier)) == 2
        @test all(
            reference === PlantSimEngine.refvalue(
                model_status(model, source_id),
                :signal,
            )
            for (source_id, reference) in
                zip(binding.source_ids, parent(carrier))
        )
    end

    simulation = run!(model; steps=2, outputs=:all)
    @test transform_calls == materialization_calls
    execution_rows = explain_execution_plan(simulation)
    @test all(
        row.inner_loop_dispatch == :concrete_homogeneous_batch &&
        isconcretetype(row.target_type) &&
        isconcretetype(row.status_type)
        for row in execution_rows
    )

    plant_a_source_rows = filter(
        row -> row.application_id == :plant_a__source,
        execution_rows,
    )
    @test length(plant_a_source_rows) == 1
    @test only(plant_a_source_rows).batch_size == 2
    @test only(plant_a_source_rows).object_ids ==
          [:plant_a_leaf_1, :plant_a_leaf_2]
    @test only(plant_a_source_rows).model_type ===
          StatusTypeTemplateSourceModel{Float64}

    plant_b_source_rows = filter(
        row -> row.application_id == :plant_b__source,
        execution_rows,
    )
    @test length(plant_b_source_rows) == 2
    @test all(row.batch_size == 1 for row in plant_b_source_rows)
    @test Set(row.model_type for row in plant_b_source_rows) == Set((
        StatusTypeTemplateSourceModel{Float64},
        StatusTypeTemplateAlternativeSourceModel{Float64},
    ))
    @test length(unique(row.status_type for row in plant_b_source_rows)) == 1

    expected_leaf_signals = Dict(
        (:plant_a__source, :plant_a_leaf_1) => Float32(4),
        (:plant_a__source, :plant_a_leaf_2) => Float32(4),
        (:plant_b__source, :plant_b_leaf_1) => Float32(2),
        (:plant_b__source, :plant_b_leaf_2) => Float32(10),
    )
    for ((application_id, object_id), expected) in expected_leaf_signals
        status = model_status(model, object_id)
        stream = outputs(simulation)[
            (application_id, ObjectId(object_id), :signal)
        ]
        @test status.signal === expected
        @test fieldtype(eltype(stream), 2) === Float32
        @test length(stream) == 2
        @test last(stream)[2] === expected
    end

    expected_plant_totals = Dict(
        (:plant_a__sum, :plant_a_root) => Float32(8),
        (:plant_b__sum, :plant_b_root) => Float32(12),
    )
    for ((application_id, object_id), expected) in expected_plant_totals
        status = model_status(model, object_id)
        stream = outputs(simulation)[
            (application_id, ObjectId(object_id), :total)
        ]
        @test status.total === expected
        @test status.signals isa PlantSimEngine.RefVector{Float32}
        @test fieldtype(eltype(stream), 2) === Float32
        @test length(stream) == 2
        @test last(stream)[2] === expected
    end

    @test all(
        fieldtype(eltype(stream), 2) === Float32
        for stream in values(outputs(simulation))
    )
    @test transform_calls == materialization_calls
end
