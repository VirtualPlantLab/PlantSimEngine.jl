using PlantSimEngine
using Test

PlantSimEngine.@process "output_destination_probe" verbose = false
PlantSimEngine.@process "output_destination_local" verbose = false
PlantSimEngine.@process "output_destination_caller" verbose = false

struct OutputDestinationProbeModel <: AbstractOutput_Destination_ProbeModel end
struct OutputDestinationLocalModel <: AbstractOutput_Destination_LocalModel end
struct OutputDestinationCallerModel <: AbstractOutput_Destination_CallerModel end

PlantSimEngine.inputs_(::OutputDestinationProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDestinationProbeModel) = NamedTuple()
PlantSimEngine.inputs_(::OutputDestinationLocalModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDestinationLocalModel) = (incident_par=0.0,)
PlantSimEngine.inputs_(::OutputDestinationCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDestinationCallerModel) = NamedTuple()
PlantSimEngine.run!(::OutputDestinationProbeModel, status, environment, constants, context) =
    nothing
PlantSimEngine.run!(::OutputDestinationCallerModel, status, environment, constants, context) =
    nothing

@testset "OutputTo declarations" begin
    selector = Many(
        scale=(:Leaf, :Internode),
        within=SceneScope(),
    )
    destination = OutputTo(
        selector;
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Required(Float64),
        ),
    )

    @test destination.selector === selector
    @test destination.vars.incident_par isa Default{Float64}
    @test destination.vars.incident_par.value == 0.0
    @test destination.vars.absorbed_par isa Required{Float64}
    @test destination.coverage === :exact

    relative_destination = OutputTo(
        Many(scale=:Leaf, within=Self());
        vars=(area=Required(Real),),
    )
    @test relative_destination.selector isa Many
    @test relative_destination.vars.area isa Required{Real}

    declarations = (organs=destination,)
    spec = ModelSpec(
        OutputDestinationProbeModel();
        name=:scene_probe,
        on=One(scale=:Scene),
        outputs_to=declarations,
    )
    @test outputs_to(spec) === declarations

    replacement = PlantSimEngine._replace_model_spec(spec; name=:renamed_scene_probe)
    @test replacement.name === :renamed_scene_probe
    @test outputs_to(replacement) === declarations

    default_spec = ModelSpec(OutputDestinationProbeModel())
    @test outputs_to(default_spec) === NamedTuple()
    @test typeof(outputs_to(default_spec)) === typeof(NamedTuple())
end

@testset "OutputTo validation" begin
    selector = Many(scale=:Leaf, within=SceneScope())
    valid_vars = (incident_par=Default(0.0),)

    @test_throws "requires at least one destination variable" OutputTo(
        selector;
        vars=NamedTuple(),
    )
    @test_throws "requires a non-empty `NamedTuple`" OutputTo(
        selector;
        vars=(:incident_par => Default(0.0),),
    )
    @test_throws "Invalid declaration(s)" OutputTo(
        selector;
        vars=(incident_par=0.0,),
    )
    @test_throws "Only `coverage=:exact`" OutputTo(
        selector;
        vars=valid_vars,
        coverage=:subset,
    )
    @test_throws "output-destination selectors must use" OutputTo(
        :leaves;
        vars=valid_vars,
    )

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
            invalid_selector;
            vars=valid_vars,
        )
    end

    model = OutputDestinationProbeModel()
    destination = OutputTo(selector; vars=valid_vars)
    @test_throws "Use a `NamedTuple` of named `OutputTo(...)` declarations" ModelSpec(
        model;
        outputs_to=(destination,),
    )
    @test_throws "must be an `OutputTo(...)` declaration" ModelSpec(
        model;
        outputs_to=(organs=selector,),
    )
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
                OutputDestinationProbeModel();
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    organs=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(
                            incident_par=Default(0.0),
                            absorbed_par=Required(Float64),
                        ),
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
    @test binding.group == :organs
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
    @test diagnostic.group == :organs
    @test diagnostic.destination_ids == [:leaf_1, :leaf_2]
    writer = only(
        row for row in Diagnostics.explain_writers(compiled)
        if row.object_id == :leaf_1 && row.variable == :incident_par
    )
    @test writer.owner_kinds == [:output_destination]
    @test writer.output_groups == [:organs]
end

@testset "output destination initialization is atomic" begin
    scene = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                OutputDestinationProbeModel();
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    organs=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(
                            incident_par=Default(0.0),
                            absorbed_par=Required(Float64),
                        ),
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

    invalid_status = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :leaf_a;
            scale=:Leaf,
            parent=:scene,
            status=Status(existing=1.0),
        ),
        Object(
            :leaf_z;
            scale=:Leaf,
            parent=:scene,
            status=(invalid=1.0,),
        );
        applications=(
            ModelSpec(
                OutputDestinationProbeModel();
                name=:scene_probe,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
    )
    leaf_a = only(
        object for object in model_objects(invalid_status; scale=:Leaf)
        if object.id == ObjectId(:leaf_a)
    )
    @test !(:incident_par in propertynames(leaf_a.status))
    @test_throws "with status type" Advanced.refresh_bindings!(invalid_status)
    @test !(:incident_par in propertynames(leaf_a.status))
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
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
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
                leaves=OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(incident_par=Default(0.0),),
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
                leaves=OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(incident_par=Default(0.0),),
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
                    first=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                    second=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
    )
    @test_throws "declares more than one canonical writer" Advanced.refresh_bindings!(
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
                    self=OutputTo(
                        One(within=Self());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
                output_routing=(incident_par=:stream_only,),
            ),
        ),
    )
    @test_throws "publishes stream-only local output `incident_par`" Advanced.refresh_bindings!(
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
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=Subtree());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
    )
    compiled = Advanced.refresh_bindings!(model)
    @test length(compiled.distributed_outputs.bindings) == 2
    by_target = compiled.distributed_outputs.by_execution_target
    @test by_target[(:plant_probe, ObjectId(:plant_a))].leaves.destination_ids ==
          ObjectId[ObjectId(:leaf_a)]
    @test by_target[(:plant_probe, ObjectId(:plant_b))].leaves.destination_ids ==
          ObjectId[ObjectId(:leaf_b)]
    @test Set(keys(compiled.distributed_outputs.writer_ownership)) == Set([
        (ObjectId(:leaf_a), :incident_par),
        (ObjectId(:leaf_b), :incident_par),
    ])
    @test compiled.distributed_outputs.destination_ids_by_application_variable[
        (:plant_probe, :incident_par)
    ] == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    @test by_target[(:plant_probe, ObjectId(:plant_a))].leaves.destination_ids ==
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
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
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
                OutputDestinationProbeModel();
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
