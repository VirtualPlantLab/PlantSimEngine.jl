using PlantSimEngine
using Test

PlantSimEngine.@process "output_destination_probe" verbose = false
PlantSimEngine.@process "output_destination_local" verbose = false
PlantSimEngine.@process "output_destination_caller" verbose = false

struct OutputDestinationProbeModel{O} <: AbstractOutput_Destination_ProbeModel
    declarations::O
end
OutputDestinationProbeModel() = OutputDestinationProbeModel((incident_par=Distributed(Default(0.0)),))
struct OutputDestinationLocalModel <: AbstractOutput_Destination_LocalModel end
struct OutputDestinationCallerModel <: AbstractOutput_Destination_CallerModel end

PlantSimEngine.inputs_(::OutputDestinationProbeModel) = NamedTuple()
PlantSimEngine.outputs_(model::OutputDestinationProbeModel) = model.declarations
PlantSimEngine.inputs_(::OutputDestinationLocalModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDestinationLocalModel) = (incident_par=0.0,)
PlantSimEngine.inputs_(::OutputDestinationCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDestinationCallerModel) = NamedTuple()
PlantSimEngine.run!(::OutputDestinationProbeModel, status, environment, constants, context) =
    nothing
PlantSimEngine.run!(::OutputDestinationCallerModel, status, environment, constants, context) =
    nothing

@testset "OutputTo declarations" begin
    selector = Many(scale=(:Leaf, :Internode), within=SceneScope())
    destination = OutputTo(selector; vars=(:incident_par, :absorbed_par))
    @test destination.selector === selector
    @test destination.vars === (:incident_par, :absorbed_par)
    @test destination.coverage === :exact
    @test OutputTo(selector).vars === nothing
    @test OutputTo(Many(scale=:Leaf, within=Self()); vars=(:area,)).selector isa Many

    declarations = (destination,)
    spec = ModelSpec(OutputDestinationProbeModel(); name=:scene_probe,
        on=One(scale=:Scene), outputs_to=declarations)
    @test outputs_to(spec) === declarations
    replacement = PlantSimEngine._replace_model_spec(spec; name=:renamed_scene_probe)
    @test replacement.name === :renamed_scene_probe
    @test outputs_to(replacement) === declarations
    @test outputs_to(ModelSpec(OutputDestinationProbeModel())) === ()
end

@testset "OutputTo validation" begin
    selector = Many(scale=:Leaf, within=SceneScope())
    valid_vars = (:incident_par,)
    for invalid_vars in ((), NamedTuple(), (:incident_par => Default(0.0),),
        (incident_par=Default(0.0),), (:incident_par, :incident_par), ("incident_par",))
        @test_throws ArgumentError OutputTo(selector; vars=invalid_vars)
    end
    @test_throws "Only `coverage=:exact`" OutputTo(selector; vars=valid_vars, coverage=:subset)
    @test_throws "output-destination selectors must use" OutputTo(:leaves; vars=valid_vars)
    invalid_selectors = (
        Many(scale=:Leaf, process=:photosynthesis),
        Many(scale=:Leaf, application=:leaf_model),
        Many(scale=:Leaf, var=:incident_par),
        Many(scale=:Leaf, policy=HoldLast()),
        Many(scale=:Leaf, window=3),
        Many(scale=:Leaf, from_status=true),
        Many(scale=:Leaf, after=:scene_light),
    )
    for invalid_selector in invalid_selectors
        @test_throws "not valid in output-destination selectors" OutputTo(
            invalid_selector; vars=valid_vars)
    end
    destination = OutputTo(selector; vars=valid_vars)
    @test_throws ArgumentError ModelSpec(OutputDestinationProbeModel();
        outputs_to=(organs=destination,))
    @test_throws ArgumentError ModelSpec(OutputDestinationProbeModel();
        outputs_to=(selector,))
end

@testset "compiled output destinations" begin
    scene = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            parent=:scene,
            status=Status(incident_par=7.0, absorbed_par=1.0),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            parent=:scene,
            status=Status(absorbed_par=2.0),
        );
        applications=(
            ModelSpec(
                OutputDestinationProbeModel((
                    incident_par=Distributed(Default(0.0)),
                    absorbed_par=Distributed(Required(Float64)),
                ));
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par, :absorbed_par),
                    ),
                ),
            ),
        ),
    )

    compiled = Advanced.refresh_bindings!(scene)
    @test compiled.scenario_plan.distributed_output_plans isa
          PlantSimEngine.CompiledDistributedOutputPlans
    @test compiled.distributed_outputs isa
          PlantSimEngine.CompiledDistributedOutputs
    binding = only(compiled.distributed_outputs.bindings)
    @test binding.application_id == :scene_probe
    @test binding.execution_object_id == ObjectId(:scene)
    @test binding.group == :output_1
    @test binding.destination_ids == ObjectId[ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test propertynames(binding.columns) == (:incident_par, :absorbed_par)
    @test collect(binding.columns.incident_par) == [7.0, 0.0]
    @test collect(binding.columns.absorbed_par) == [1.0, 2.0]

    binding.columns.incident_par[2] = 9.0
    leaf_2 = only(object for object in model_objects(scene; scale=:Leaf) if object.id == ObjectId(:leaf_2))
    @test leaf_2.status.incident_par == 9.0

    ownership = compiled.distributed_outputs.writer_ownership
    @test only(ownership[(ObjectId(:leaf_1), :incident_par)]).application_id ==
          :scene_probe
    diagnostic = only(Diagnostics.explain_output_bindings(compiled))
    @test diagnostic.application_id == :scene_probe
    @test diagnostic.variables == (:incident_par, :absorbed_par)
    @test diagnostic.destination_ids == [:leaf_1, :leaf_2]
    writer = only(
        row for row in Diagnostics.explain_writers(compiled)
        if row.object_id == :leaf_1 && row.variable == :incident_par
    )
    @test writer.owner_kinds == [:output_destination]
    @test writer.output_groups == [:output_1]
end

@testset "output destination initialization is atomic" begin
    scene = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                OutputDestinationProbeModel((
                    incident_par=Distributed(Default(0.0)),
                    absorbed_par=Distributed(Required(Float64)),
                ));
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par, :absorbed_par),
                    ),
                ),
            ),
        ),
    )
    leaf = only(model_objects(scene; scale=:Leaf))
    @test isnothing(leaf.status)
    @test_throws "Missing required distributed-output destination" Advanced.refresh_bindings!(
        scene,
    )
    @test isnothing(leaf.status)

    initial_status = Status(existing=1.0)
    initial_ref = PlantSimEngine.refvalue(initial_status, :existing)
    @test_throws "Initial object status must be a Status or nothing" CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene, status=initial_status),
        Object(:leaf_z; scale=:Leaf, parent=:scene, status=(invalid=1.0,)),
    )
    @test propertynames(initial_status) == (:existing,)
    @test PlantSimEngine.refvalue(initial_status, :existing) === initial_ref
    @test initial_status.existing == 1.0

    missing_status = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene,
            status=Status(existing=1.0, absorbed_par=2.0)),
        Object(:leaf_z; scale=:Leaf, parent=:scene, status=Status(existing=3.0));
        applications=(
            ModelSpec(
                OutputDestinationProbeModel((
                    incident_par=Distributed(Default(0.0)),
                    absorbed_par=Distributed(Required(Float64)),
                ));
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    OutputTo(Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par, :absorbed_par)),
                ),
            ),
        ),
    )
    leaves = model_objects(missing_status; scale=:Leaf)
    statuses = [object.status for object in leaves]
    references = [PlantSimEngine.refvalue(status, :existing) for status in statuses]
    @test all(status -> !(:incident_par in propertynames(status)), statuses)
    @test_throws "Missing required distributed-output destination" Advanced.refresh_bindings!(
        missing_status,
    )
    @test all(object.status === status for (object, status) in zip(leaves, statuses))
    @test all(PlantSimEngine.refvalue(status, :existing) === reference
        for (status, reference) in zip(statuses, references))
    @test all(status -> !(:incident_par in propertynames(status)), statuses)
    @test sort([status.existing for status in statuses]) == [1.0, 3.0]

end

@testset "empty and lifecycle-refreshed output destinations" begin
    scene = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                OutputDestinationProbeModel();
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par,),
                    ),
                ),
            ),
        ),
    )
    first_compiled = Advanced.refresh_bindings!(scene)
    first_binding = only(first_compiled.distributed_outputs.bindings)
    @test isempty(first_binding.destination_ids)
    @test isempty(first_binding.columns.incident_par)

    register_object!(scene, Object(:leaf; scale=:Leaf); parent=:scene)
    second_compiled = Advanced.refresh_bindings!(scene)
    @test second_compiled !== first_compiled
    second_binding = only(second_compiled.distributed_outputs.bindings)
    @test second_binding.destination_ids == ObjectId[ObjectId(:leaf)]
    @test only(model_objects(scene; scale=:Leaf)).status.incident_par == 0.0

    dynamic_scene = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=scene.applications,
    )
    simulation = run!(dynamic_scene; outputs=:none, performance=true)
    initial_compiled_type = typeof(simulation.compiled)
    initial_scenario_plan = simulation.compiled.scenario_plan
    initial_status_view = only(values(simulation.compiled.status_views_by_target))
    register_object!(dynamic_scene, Object(:dynamic_leaf; scale=:Leaf); parent=:scene)
    continue!(simulation)
    @test typeof(simulation.compiled) === initial_compiled_type
    @test simulation.compiled.scenario_plan === initial_scenario_plan
    @test only(values(simulation.compiled.status_views_by_target)) ===
          initial_status_view
    performance = Advanced.runtime_performance(simulation)
    @test get(performance.counts, :status_views_constructed, 0) == 0
    @test performance.counts[:execution_targets_constructed] == 1
    @test only(model_objects(dynamic_scene; scale=:Leaf)).status.incident_par == 0.0
end

@testset "distributed writer ownership and collisions" begin
    function writer_scene(distributed_spec)
        return CompositeModel(
            Object(:scene; scale=:Scene),
            Object(:leaf; scale=:Leaf, parent=:scene);
            applications=(
                ModelSpec(
                    OutputDestinationLocalModel();
                    name=:leaf_source,
                    on=One(scale=:Leaf),
                ),
                distributed_spec,
            ),
        )
    end

    ambiguous = writer_scene(
        ModelSpec(
            OutputDestinationProbeModel();
            name=:scene_probe,
            on=One(scale=:Scene),
            outputs_to=(
                OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(:incident_par,),
                ),
            ),
        ),
    )
    @test_throws "Ambiguous canonical writers" Advanced.refresh_bindings!(ambiguous)

    ordered = writer_scene(
        ModelSpec(
            OutputDestinationProbeModel();
            name=:scene_probe,
            on=One(scale=:Scene),
            outputs_to=(
                OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(:incident_par,),
                ),
            ),
            updates=Updates(:incident_par; after=:leaf_source),
        ),
    )
    ordered_compiled = Advanced.refresh_bindings!(ordered)
    writer = only(Diagnostics.explain_writers(ordered_compiled))
    @test writer.application_ids == [:leaf_source, :scene_probe]
    @test writer.owner_kinds == [:application_target, :output_destination]
    @test writer.duplicate

    overlapping = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                OutputDestinationProbeModel();
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par,),
                    ),
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par,),
                    ),
                ),
            ),
        ),
    )
    @test_throws ArgumentError Advanced.refresh_bindings!(
        overlapping,
    )

    stream_only_self_collision = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(
                OutputDestinationLocalModel();
                name=:stream_only_self_writer,
                on=One(scale=:Leaf),
                outputs_to=(
                    OutputTo(
                        One(within=Self());
                        vars=(:incident_par,),
                    ),
                ),
                output_routing=(incident_par=:stream_only,),
            ),
        ),
    )
    @test_throws ArgumentError Advanced.refresh_bindings!(
        stream_only_self_collision,
    )
end

@testset "output destinations remain scoped per execution object" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:plant_a),
        Object(:leaf_b; scale=:Leaf, parent=:plant_b);
        applications=(
            ModelSpec(
                OutputDestinationProbeModel();
                name=:plant_probe,
                on=Many(scale=:Plant),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=Subtree());
                        vars=(:incident_par,),
                    ),
                ),
            ),
        ),
    )
    compiled = Advanced.refresh_bindings!(model)
    @test length(compiled.distributed_outputs.bindings) == 2
    by_target = compiled.distributed_outputs.by_execution_target
    @test by_target[(:plant_probe, ObjectId(:plant_a))].output_1.destination_ids ==
          ObjectId[ObjectId(:leaf_a)]
    @test by_target[(:plant_probe, ObjectId(:plant_b))].output_1.destination_ids ==
          ObjectId[ObjectId(:leaf_b)]
    @test Set(keys(compiled.distributed_outputs.writer_ownership)) == Set([
        (ObjectId(:leaf_a), :incident_par),
        (ObjectId(:leaf_b), :incident_par),
    ])
    @test compiled.distributed_outputs.destination_ids_by_application_variable[
        (:plant_probe, :incident_par)
    ] == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    @test by_target[(:plant_probe, ObjectId(:plant_a))].output_1.destination_ids ==
          ObjectId[ObjectId(:leaf_a)]

    dynamic_model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:plant_a);
        applications=model.applications,
    )
    simulation = run!(dynamic_model; outputs=:none)
    initial_compiled_type = typeof(simulation.compiled)
    register_object!(
        dynamic_model,
        Object(:plant_b; scale=:Plant);
        parent=:scene,
    )
    register_object!(
        dynamic_model,
        Object(:leaf_b; scale=:Leaf);
        parent=:plant_b,
    )
    continue!(simulation)
    @test typeof(simulation.compiled) === initial_compiled_type
    @test length(simulation.compiled.distributed_outputs.bindings) == 2
    @test only(
        object for object in model_objects(dynamic_model; scale=:Leaf)
        if object.id == ObjectId(:leaf_b)
    ).status.incident_par == 0.0
end


@testset "manual distributed outputs are rejected while targets are empty" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                OutputDestinationCallerModel();
                name=:caller,
                on=One(scale=:Scene),
                calls=(probe=Many(application=:manual_probe),),
            ),
            ModelSpec(
                OutputDestinationProbeModel();
                name=:manual_probe,
                on=Many(scale=:Leaf),
                outputs_to=(
                    OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(:incident_par,),
                    ),
                ),
            ),
        ),
    )
    @test_throws "manual-call-only" Advanced.refresh_bindings!(model)
end

@testset "no distributed outputs keep the singleton path" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                OutputDestinationCallerModel();
                name=:plain_probe,
                on=One(scale=:Scene),
            ),
        ),
    )
    compiled = Advanced.refresh_bindings!(model)
    @test compiled.scenario_plan.distributed_output_plans isa
          PlantSimEngine.NoCompiledDistributedOutputPlans
    @test compiled.distributed_outputs isa
          PlantSimEngine.NoCompiledDistributedOutputs
    @test isempty(Diagnostics.explain_output_bindings(compiled))
end

struct OutputDestinationLocalPayload
    coefficient::Float32
end

function output_destination_schema_scene(model, destinations; leaf_status=nothing)
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene, status=leaf_status);
        applications=(ModelSpec(model; name=:schema_probe, on=One(scale=:Scene),
            outputs_to=destinations),),
    )
end

@testset "model-owned distributed schemas and inferred variables" begin
    payload = OutputDestinationLocalPayload(3.0f0)
    model = OutputDestinationProbeModel((
        incident_par=Distributed(Default(1.0f0)),
        local_array=Float32[2, 3],
        local_tuple=(4, 5),
        local_payload=payload,
        absorbed_par=Distributed(Default(2.0f0)),
        local_total=0.0f0,
    ))
    @test outputs(model) == (:incident_par, :local_array, :local_tuple,
        :local_payload, :absorbed_par, :local_total)
    types = PlantSimEngine.variables_typed(model)
    @test types.incident_par === Float32
    @test types.absorbed_par === Float32
    @test types.local_array === Vector{Float32}
    @test types.local_payload === OutputDestinationLocalPayload

    inferred = output_destination_schema_scene(model,
        (OutputTo(Many(scale=:Leaf)),))
    explicit = output_destination_schema_scene(model,
        (OutputTo(Many(scale=:Leaf); vars=(:incident_par, :absorbed_par)),))
    for scenario in (inferred, explicit)
        compiled = Advanced.refresh_bindings!(scenario)
        leaf = model_object(scenario, :leaf).status
        scene = model_object(scenario, :scene).status
        @test leaf.incident_par === 1.0f0
        @test leaf.absorbed_par === 2.0f0
        @test !(:local_total in propertynames(leaf))
        @test !(:incident_par in propertynames(scene))
        @test !(:absorbed_par in propertynames(scene))
        @test scene.local_array == Float32[2, 3]
        @test scene.local_tuple == (4, 5)
        @test scene.local_payload == payload
        @test scene.local_total === 0.0f0
        diagnostic = only(Diagnostics.explain_output_bindings(compiled))
        @test diagnostic.variables == (:incident_par, :absorbed_par)
        @test diagnostic.destination_index == 1
        @test diagnostic.origin == (scenario === inferred ? :inferred : :explicit)
        application = only(Diagnostics.explain_applications(compiled))
        @test application.outputs == outputs(model)
        @test application.local_outputs == (:local_array, :local_tuple, :local_payload, :local_total)
        @test application.distributed_outputs == (:incident_par, :absorbed_par)
    end
    inferred_binding = only(Advanced.refresh_bindings!(inferred).distributed_outputs.bindings)
    explicit_binding = only(Advanced.refresh_bindings!(explicit).distributed_outputs.bindings)
    @test inferred_binding.destination_ids == explicit_binding.destination_ids
    @test collect(inferred_binding.columns.incident_par) ==
        collect(explicit_binding.columns.incident_par)
end

@testset "invalid distributed partitions fail before destination mutation" begin
    probe = OutputDestinationProbeModel((
        incident_par=Distributed(Default(1.0)),
        absorbed_par=Distributed(Default(2.0)),
        local_total=0.0,
    ))
    selector = Many(scale=:Leaf)
    incident = OutputTo(selector; vars=(:incident_par,))
    absorbed = OutputTo(selector; vars=(:absorbed_par,))
    inferred = OutputTo(selector)
    invalid_partitions = (
        missing_all=(),
        missing_one=(incident,),
        unknown=(OutputTo(selector; vars=(:incident_par, :absorbed_par, :typo)),),
        local_variable=(OutputTo(selector; vars=(:incident_par, :absorbed_par, :local_total)),),
        duplicate=(incident, absorbed, incident),
        inferred_first=(inferred, absorbed),
        inferred_last=(incident, inferred),
        both_inferred=(inferred, inferred),
    )
    for (case, destinations) in pairs(invalid_partitions)
        @testset "$case" begin
            scenario = output_destination_schema_scene(probe, destinations;
                leaf_status=Status(existing=7.0))
            @test_throws ArgumentError Advanced.refresh_bindings!(scenario)
            leaf = model_object(scenario, :leaf).status
            @test propertynames(leaf) == (:existing,)
            @test leaf.existing == 7.0
        end
    end
    for destinations in ((inferred,), (incident,))
        scenario = output_destination_schema_scene(OutputDestinationLocalModel(), destinations)
        @test_throws ArgumentError Advanced.refresh_bindings!(scenario)
        @test isnothing(model_object(scenario, :leaf).status)
    end
    # Explicit partitions are independent of entry order.
    for destinations in ((incident, absorbed), (absorbed, incident))
        scenario = output_destination_schema_scene(probe, destinations)
        Advanced.refresh_bindings!(scenario)
        @test model_object(scenario, :leaf).status.incident_par == 1.0
        @test model_object(scenario, :leaf).status.absorbed_par == 2.0
    end
end

@testset "Required distributed values preserve compatible destination types" begin
    probe = OutputDestinationProbeModel((incident_par=Distributed(Required(Real)),))
    for initial in (1.0f0, 1.0, big"1.0")
        scenario = output_destination_schema_scene(probe, (OutputTo(One(scale=:Leaf)),);
            leaf_status=Status(incident_par=initial))
        Advanced.refresh_bindings!(scenario)
        @test model_object(scenario, :leaf).status.incident_par == initial
        @test typeof(model_object(scenario, :leaf).status.incident_par) === typeof(initial)
    end
    invalid = output_destination_schema_scene(probe, (OutputTo(Many(scale=:Leaf)),);
        leaf_status=Status(incident_par="invalid"))
    @test_throws Exception Advanced.refresh_bindings!(invalid)
    @test model_object(invalid, :leaf).status.incident_par == "invalid"
    @test_throws ArgumentError Distributed(0.0)
    @test_throws ArgumentError Distributed(Distributed(Default(0.0)))
end

@testset "distributed defaults follow template and effective override models" begin
    probe(value) = OutputDestinationProbeModel((
        incident_par=Distributed(Default(value)),
        absorbed_par=Distributed(Default(2 * value)),
    ))
    reversed_probe = OutputDestinationProbeModel((
        absorbed_par=Distributed(Default(22.0f0)),
        incident_par=Distributed(Default(11.0f0)),
    ))
    template = CompositeModelTemplate((
        ModelSpec(probe(1.0f0); name=:probe, on=Many(scale=:Plant),
            outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree())),)),
    ))
    function instance(name; overrides=NamedTuple(), object_overrides=())
        root_id = Symbol(:plant_, name)
        leaf_id = Symbol(:leaf_, name)
        return ObjectInstance(name, template;
            root=Object(root_id; scale=:Plant),
            objects=(Object(leaf_id; scale=:Leaf, parent=root_id),),
            overrides=overrides, object_overrides=object_overrides)
    end
    scenario = CompositeModel(
        instance(:a),
        instance(:b; overrides=(probe=probe(9.0f0),)),
        instance(:c; object_overrides=(Override(object=:plant_c,
            application=:probe, model=reversed_probe),)),
    )
    compiled = Advanced.refresh_bindings!(scenario)
    @test model_object(scenario, :leaf_a).status.incident_par === 1.0f0
    @test model_object(scenario, :leaf_b).status.incident_par === 9.0f0
    @test model_object(scenario, :leaf_c).status.incident_par === 11.0f0
    @test model_object(scenario, :leaf_a).status.absorbed_par === 2.0f0
    @test model_object(scenario, :leaf_b).status.absorbed_par === 18.0f0
    @test model_object(scenario, :leaf_c).status.absorbed_par === 22.0f0
    @test length(Diagnostics.explain_output_bindings(compiled)) == 3
    for root_id in (:plant_a, :plant_b, :plant_c)
        @test !(:incident_par in propertynames(model_object(scenario, root_id).status))
    end

    for replacement in (
        OutputDestinationProbeModel((
            incident_par=0.0f0, absorbed_par=Distributed(Default(0.0f0)),
        )),
        OutputDestinationProbeModel((
            unknown=Distributed(Default(0.0f0)), absorbed_par=Distributed(Default(0.0f0)),
        )),
        OutputDestinationProbeModel((
            incident_par=Distributed(Default("invalid")), absorbed_par=Distributed(Default(0.0f0)),
        )),
    )
        @test_throws "incompatible" CompositeModel(
            instance(:invalid; overrides=(probe=replacement,)))
        @test_throws "incompatible" CompositeModel(
            instance(:invalid; object_overrides=(Override(object=:plant_invalid,
                application=:probe, model=replacement),)))
    end
end

@testset "distributed outputs reject stream-only routing before mutation" begin
    for selector in (One(within=Self()), Many(scale=:Leaf))
        scenario = CompositeModel(
            Object(:scene; scale=:Scene, status=Status(existing=1.0)),
            Object(:leaf; scale=:Leaf, parent=:scene, status=Status(existing=2.0));
            applications=(ModelSpec(OutputDestinationProbeModel(); name=:private_distributed,
                on=One(scale=:Scene), outputs_to=(OutputTo(selector),),
                output_routing=(incident_par=:stream_only,)),),
        )
        @test_throws "stream_only" Advanced.refresh_bindings!(scenario)
        @test propertynames(model_object(scenario, :scene).status) == (:existing,)
        @test propertynames(model_object(scenario, :leaf).status) == (:existing,)
        @test model_object(scenario, :scene).status.existing == 1.0
        @test model_object(scenario, :leaf).status.existing == 2.0
    end
end

struct OutputDestinationChangingProbe{R,C} <: AbstractOutput_Destination_ProbeModel
    seed::R
    reads::C
end
PlantSimEngine.inputs_(::OutputDestinationChangingProbe) = NamedTuple()
function PlantSimEngine.outputs_(model::OutputDestinationChangingProbe)
    model.reads[] += 1
    return (incident_par=Distributed(Default(model.seed[])),)
end
PlantSimEngine.run!(::OutputDestinationChangingProbe, status, environment, constants, context) = nothing

@testset "distributed declaration types belong to their effective producer" begin
    narrow = OutputDestinationChangingProbe(Ref{Any}(1f0), Ref(0))
    wide = OutputDestinationChangingProbe(Ref{Any}(2.0), Ref(0))
    first_cell, second_cell = Ref(3f0), Ref(4.0)
    model = CompositeModel(
        Object(:plant_a; scale=:Plant), Object(:plant_b; scale=:Plant),
        Object(:leaf_a; scale=:Leaf, parent=:plant_a,
            status=Status((incident_par=first_cell,))),
        Object(:leaf_b; scale=:Leaf, parent=:plant_b,
            status=Status((incident_par=second_cell,)));
        applications=(
            ModelSpec(narrow; name=:narrow, on=One(id=:plant_a),
                outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:incident_par,)),)),
            ModelSpec(wide; name=:wide, on=One(id=:plant_b),
                outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:incident_par,)),)),
        ))
    compiled = Advanced.refresh_bindings!(model)
    bindings = compiled.distributed_outputs.bindings
    @test length(bindings) == 2
    # The global row union contains both declarations for the SAME route type.
    @test typeof(first(bindings).plan) === typeof(last(bindings).plan)
    @test model_status(model, :leaf_a).incident_par === 3f0
    @test model_status(model, :leaf_b).incident_par === 4.0

    # The other producer's Float64 witness must not authorize this change.
    # A supplied newborn field also makes the default value unnecessary, so
    # validation must happen before deciding whether initialization is needed.
    narrow.seed[] = 9.0
    newborn_cell = Ref(5f0)
    register_object!(model, Object(:leaf_z; scale=:Leaf, parent=:plant_a,
        status=Status((incident_par=newborn_cell,))))
    before = model.binding_cache
    original_ids = map(binding -> copy(binding.destination_ids), bindings)
    reads = (narrow.reads[], wide.reads[])
    @test_throws "schema changed after preparation" Advanced.refresh_bindings!(model)
    @test narrow.reads[] == reads[1] + 1
    @test wide.reads[] == reads[2]
    @test model.binding_cache === before
    @test map(binding -> binding.destination_ids, bindings) == original_ids
    @test PlantSimEngine.refvalue(model_status(model, :leaf_a), :incident_par) === first_cell
    @test PlantSimEngine.refvalue(model_status(model, :leaf_b), :incident_par) === second_cell
    @test PlantSimEngine.refvalue(model_status(model, :leaf_z), :incident_par) === newborn_cell
    @test first_cell[] === 3f0
    @test second_cell[] === 4.0
    @test newborn_cell[] === 5f0
end
