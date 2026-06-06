using Dates
using PlantSimEngine
using PlantSimEngine.Examples
using Test

PlantSimEngine.@process "scene_object_default_input_consumer" verbose = false

struct SceneObjectDefaultInputConsumerModel <: AbstractScene_Object_Default_Input_ConsumerModel end

PlantSimEngine.inputs_(::SceneObjectDefaultInputConsumerModel) = (leaf_carbon=[0.0],)
PlantSimEngine.outputs_(::SceneObjectDefaultInputConsumerModel) = (plant_carbon=0.0,)
PlantSimEngine.dep(::SceneObjectDefaultInputConsumerModel) = (
    leaf_carbon=Input(Many(scale=:Leaf, within=Self(), var=:leaf_carbon)),
)

PlantSimEngine.@process "scene_object_default_call_consumer" verbose = false

struct SceneObjectDefaultCallConsumerModel <: AbstractScene_Object_Default_Call_ConsumerModel end

PlantSimEngine.inputs_(::SceneObjectDefaultCallConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectDefaultCallConsumerModel) = (energy_balance=0.0,)
PlantSimEngine.dep(::SceneObjectDefaultCallConsumerModel) = (
    stomata=Call(scale=:Leaf, process=:stomatal_conductance),
)

PlantSimEngine.@process "scene_object_stomata" verbose = false

struct SceneObjectStomataModel <: AbstractScene_Object_StomataModel end

PlantSimEngine.inputs_(::SceneObjectStomataModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectStomataModel) = (gs=0.0,)

PlantSimEngine.@process "scene_object_leaf_energy" verbose = false

struct SceneObjectLeafEnergyModel <: AbstractScene_Object_Leaf_EnergyModel end

PlantSimEngine.inputs_(::SceneObjectLeafEnergyModel) = (leaf_areas=[0.0],)
PlantSimEngine.outputs_(::SceneObjectLeafEnergyModel) = (leaf_temperature=25.0,)
PlantSimEngine.dep(::SceneObjectLeafEnergyModel) = (
    stomata=Call(process=:scene_object_stomata),
)

PlantSimEngine.@process "scene_object_carrier_consumer" verbose = false

struct SceneObjectCarrierConsumerModel <: AbstractScene_Object_Carrier_ConsumerModel end

PlantSimEngine.inputs_(::SceneObjectCarrierConsumerModel) = (leaf_areas=[0.0], leaf_tokens=Any[])
PlantSimEngine.outputs_(::SceneObjectCarrierConsumerModel) = (carrier_total=0.0,)

function PlantSimEngine.run!(::SceneObjectCarrierConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.carrier_total = sum(status.leaf_areas)
    return nothing
end

PlantSimEngine.@process "scene_object_environment_probe" verbose = false

struct SceneObjectEnvironmentProbeModel <: AbstractScene_Object_Environment_ProbeModel end

PlantSimEngine.inputs_(::SceneObjectEnvironmentProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectEnvironmentProbeModel) = (temperature_seen=0.0,)
PlantSimEngine.meteo_inputs_(::SceneObjectEnvironmentProbeModel) = (T=0.0, CO2=0.0)

function PlantSimEngine.run!(::SceneObjectEnvironmentProbeModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temperature_seen = meteo.T
    return nothing
end

PlantSimEngine.@process "scene_object_environment_update" verbose = false

struct SceneObjectEnvironmentUpdateModel <: AbstractScene_Object_Environment_UpdateModel end

PlantSimEngine.inputs_(::SceneObjectEnvironmentUpdateModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectEnvironmentUpdateModel) = (temperature_update=0.0,)
PlantSimEngine.meteo_inputs_(::SceneObjectEnvironmentUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_outputs_(::SceneObjectEnvironmentUpdateModel) = (T=0.0,)

function PlantSimEngine.run!(::SceneObjectEnvironmentUpdateModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temperature_update = meteo.T + 1.0
    status.T = status.temperature_update
    return nothing
end

PlantSimEngine.@process "scene_object_signal_source" verbose = false

struct SceneObjectSignalSourceModel <: AbstractScene_Object_Signal_SourceModel end

PlantSimEngine.inputs_(::SceneObjectSignalSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectSignalSourceModel) = (signal=0.0,)

function PlantSimEngine.run!(::SceneObjectSignalSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += 1.0
    return nothing
end

struct SceneObjectParameterizedSignalModel{T} <: AbstractScene_Object_Signal_SourceModel
    increment::T
end

PlantSimEngine.inputs_(::SceneObjectParameterizedSignalModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectParameterizedSignalModel) = (signal=0.0,)

function PlantSimEngine.run!(model::SceneObjectParameterizedSignalModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += model.increment
    return nothing
end

PlantSimEngine.@process "scene_object_plant_signal_sum" verbose = false

struct SceneObjectPlantSignalSumModel <: AbstractScene_Object_Plant_Signal_SumModel end

PlantSimEngine.inputs_(::SceneObjectPlantSignalSumModel) = (signals=[0.0],)
PlantSimEngine.outputs_(::SceneObjectPlantSignalSumModel) = (signal_total=0.0,)

function PlantSimEngine.run!(::SceneObjectPlantSignalSumModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal_total = sum(status.signals)
    return nothing
end

PlantSimEngine.@process "scene_object_signal_caller" verbose = false

struct SceneObjectSignalCallerModel <: AbstractScene_Object_Signal_CallerModel end

PlantSimEngine.inputs_(::SceneObjectSignalCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectSignalCallerModel) = (called_signal=0.0,)
PlantSimEngine.dep(::SceneObjectSignalCallerModel) = (
    signal=Call(process=:scene_object_signal_source),
)

function PlantSimEngine.run!(::SceneObjectSignalCallerModel, models, status, meteo, constants=nothing, extra=nothing)
    target = dependency_target(extra, :signal)
    run_call!(target)
    status.called_signal = target.status.signal
    return nothing
end

PlantSimEngine.@process "scene_object_signal_consumer" verbose = false

struct SceneObjectSignalConsumerModel <: AbstractScene_Object_Signal_ConsumerModel end

PlantSimEngine.inputs_(::SceneObjectSignalConsumerModel) = (signal=0.0,)
PlantSimEngine.outputs_(::SceneObjectSignalConsumerModel) = (observed_signal=0.0,)

function PlantSimEngine.run!(::SceneObjectSignalConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.observed_signal = status.signal
    return nothing
end

PlantSimEngine.@process "scene_object_cycle_a" verbose = false

struct SceneObjectCycleAModel <: AbstractScene_Object_Cycle_AModel end

PlantSimEngine.inputs_(::SceneObjectCycleAModel) = (cycle_b=0.0,)
PlantSimEngine.outputs_(::SceneObjectCycleAModel) = (cycle_a=0.0,)

PlantSimEngine.@process "scene_object_cycle_b" verbose = false

struct SceneObjectCycleBModel <: AbstractScene_Object_Cycle_BModel end

PlantSimEngine.inputs_(::SceneObjectCycleBModel) = (cycle_a=0.0,)
PlantSimEngine.outputs_(::SceneObjectCycleBModel) = (cycle_b=0.0,)

PlantSimEngine.@process "scene_object_temporal_sum" verbose = false

struct SceneObjectTemporalSumModel <: AbstractScene_Object_Temporal_SumModel end

PlantSimEngine.inputs_(::SceneObjectTemporalSumModel) = (signal_sum=0.0,)
PlantSimEngine.outputs_(::SceneObjectTemporalSumModel) = (temporal_total=0.0,)

function PlantSimEngine.run!(::SceneObjectTemporalSumModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temporal_total = status.signal_sum
    return nothing
end

PlantSimEngine.@process "scene_object_biomass_source" verbose = false

struct SceneObjectBiomassSourceModel <: AbstractScene_Object_Biomass_SourceModel end

PlantSimEngine.inputs_(::SceneObjectBiomassSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectBiomassSourceModel) = (biomass=0.0,)

function PlantSimEngine.run!(::SceneObjectBiomassSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.biomass = 10.0
    return nothing
end

PlantSimEngine.@process "scene_object_biomass_pruner" verbose = false

struct SceneObjectBiomassPrunerModel <: AbstractScene_Object_Biomass_PrunerModel end

PlantSimEngine.inputs_(::SceneObjectBiomassPrunerModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneObjectBiomassPrunerModel) = (biomass=0.0,)

function PlantSimEngine.run!(::SceneObjectBiomassPrunerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.biomass = 0.0
    return nothing
end

mutable struct SceneObjectGridBackend <: PlantSimEngine.AbstractEnvironmentBackend
    binds::Vector{Any}
    index_updates::Vector{Any}
end

SceneObjectGridBackend(binds::Vector{Any}=Any[]) = SceneObjectGridBackend(binds, Any[])

struct SceneObjectTaggedValue
    value::Int
end

PlantSimEngine.base_step_seconds(::SceneObjectGridBackend) = 3600.0
PlantSimEngine.get_nsteps(::SceneObjectGridBackend) = 1
PlantSimEngine.environment_variables(::SceneObjectGridBackend) = Set([:T, :CO2])

function PlantSimEngine.bind_environment(
    backend::SceneObjectGridBackend,
    object::Object,
    support,
    config,
)
    object_geometry = geometry(object)
    cell = isnothing(object_geometry) ? :global : object_geometry.cell
    push!(backend.binds, (object=object.id.value, application=support.domain, cell=cell, config=config))
    return cell
end

function PlantSimEngine.update_index!(backend::SceneObjectGridBackend, entities)
    push!(
        backend.index_updates,
        [
            (
                id=entity.id,
                scale=entity.scale,
                kind=entity.kind,
                geometry=entity.geometry,
                position=entity.position,
                bounds=entity.bounds,
            )
            for entity in entities
        ],
    )
    return nothing
end

mutable struct SceneObjectMutableEnvironmentBackend <: PlantSimEngine.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    cells_by_status::Dict{UInt,Symbol}
    writes::Vector{Any}
end

SceneObjectMutableEnvironmentBackend(values::Pair...) =
    SceneObjectMutableEnvironmentBackend(Dict{Symbol,Float64}(values), Dict{UInt,Symbol}(), Any[])

PlantSimEngine.base_step_seconds(::SceneObjectMutableEnvironmentBackend) = 3600.0
PlantSimEngine.get_nsteps(::SceneObjectMutableEnvironmentBackend) = 1
PlantSimEngine.environment_variables(::SceneObjectMutableEnvironmentBackend) = Set([:T, :CO2])

function PlantSimEngine.bind_environment(
    backend::SceneObjectMutableEnvironmentBackend,
    object::Object,
    support,
    config,
)
    cell = object.geometry.cell
    backend.cells_by_status[objectid(object.status)] = cell
    return cell
end

function PlantSimEngine.sample(
    backend::SceneObjectMutableEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    time,
)
    variable == :CO2 && return 410.0
    variable == :T || error("Unexpected variable `$(variable)`.")
    cell = backend.cells_by_status[objectid(support.status)]
    return backend.values[cell]
end

function PlantSimEngine.scatter!(
    backend::SceneObjectMutableEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    value,
    time,
)
    variable == :T || error("Unexpected variable `$(variable)`.")
    cell = backend.cells_by_status[objectid(support.status)]
    backend.values[cell] = value
    push!(
        backend.writes,
        (
            application=support.domain,
            process=support.process,
            cell=cell,
            variable=variable,
            value=value,
            time=time,
        ),
    )
    return nothing
end

@testset "Unified scene/object API" begin
    scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(x=1.0, y=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1),
    )

    @test object_ids(scene; scale=:Leaf) == [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test object_ids(scene; kind=:plant, species=:oil_palm) == [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:plant_1)]
    @test only(scene_objects(scene; scale=:Scene)).id == ObjectId(:scene)

    leaf_2 = move_object!(scene, :leaf_2, (x=2.0, y=0.0))
    @test leaf_2.geometry == (x=2.0, y=0.0)
    @test geometry(leaf_2) == (x=2.0, y=0.0)
    @test position(leaf_2) == (x=2.0, y=0.0)
    @test isnothing(bounds(leaf_2))
    bounded_leaf = Object(:bounded_leaf; scale=:Leaf, geometry=(position=(x=1.0, y=2.0, z=3.0), bounds=(radius=0.5,)))
    @test position(bounded_leaf) == (x=1.0, y=2.0, z=3.0)
    @test bounds(bounded_leaf) == (radius=0.5,)

    new_axis = register_object!(scene, Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm); parent=:plant_1)
    @test new_axis.parent == ObjectId(:plant_1)
    @test ObjectId(:axis_1) in only(scene_objects(scene; scale=:Plant)).children

    reparent_object!(scene, :leaf_2, :axis_1)
    @test only(scene_objects(scene; name=nothing, scale=:Axis)).children == [ObjectId(:leaf_2)]
    @test ObjectId(:leaf_2) ∉ only(scene_objects(scene; scale=:Plant)).children

    removed_axis = remove_object!(scene, :axis_1)
    @test removed_axis.id == ObjectId(:axis_1)
    @test object_ids(scene; scale=:Axis) == ObjectId[]
    @test object_ids(scene; name=:leaf_2) == ObjectId[]

    object_rows = explain_objects(scene)
    @test length(object_rows) == 3
    @test any(row -> row.id == :leaf_1 && row.has_geometry, object_rows)
    @test any(row -> row.id == :plant_1 && row.children == [ObjectId(:leaf_1).value], object_rows)

    selector_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:axis_1),
        Object(:plant_2; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_2, parent=:scene),
        Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_2),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene),
    )

    scope_rows = explain_scopes(selector_scene)
    scene_scope = only(row for row in scope_rows if row.scope_type == :scene)
    @test scene_scope.selector isa SceneScope
    @test scene_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :leaf_3, :plant_1, :plant_2, :scene, :soil]
    plant_1_scope = only(row for row in scope_rows if row.scope_type == :object_subtree && row.root_id == :plant_1)
    @test plant_1_scope.selector isa Self
    @test plant_1_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :plant_1]
    palm_2_scope = only(row for row in scope_rows if row.scope_type == :named_scope && row.name == :palm_2)
    @test palm_2_scope.selector isa Scope
    @test palm_2_scope.root_id == :plant_2
    @test palm_2_scope.object_ids == [:leaf_3, :plant_2]
    leaf_label_scope = only(row for row in scope_rows if row.scope_type == :scale && row.scale == :Leaf)
    @test leaf_label_scope.selector == (:scale => :Leaf)
    @test leaf_label_scope.object_ids == [:leaf_1, :leaf_2, :leaf_3]
    oil_palm_scope = only(row for row in scope_rows if row.scope_type == :species && row.species == :oil_palm)
    @test oil_palm_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :leaf_3, :plant_1, :plant_2]

    @test resolve_object_ids(selector_scene, Many(scale=:Leaf)) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]
    @test only(resolve_objects(selector_scene, One(scale=:Scene))).id == ObjectId(:scene)
    @test resolve_object_ids(selector_scene, Many(Kind(:plant), Scale(:Leaf))) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Self()); context=:plant_1) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Self()); context=:leaf_2) ==
          [ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=SelfPlant()); context=:leaf_2) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Ancestor(scale=:Axis)); context=:leaf_2) ==
          [ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Scope(:palm_2))) ==
          [ObjectId(:leaf_3)]
    @test resolve_object_ids(selector_scene, OptionalOne(scale=:Flower)) == ObjectId[]
    @test_throws ErrorException resolve_object_ids(selector_scene, One(scale=:Flower))
    @test_throws ErrorException resolve_object_ids(selector_scene, One(scale=:Leaf))
    @test_throws ErrorException resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Self()))
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf); context=:plant_1) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]

    shared_signal_model = SceneObjectParameterizedSignalModel(1.0)
    shared_template_parameters = Dict(:signal_increment => 1.0)
    plant_template = ObjectTemplate(
        (
            ModelSpec(shared_signal_model; name=:signal_source) |>
            AppliesTo(Many(scale=:Leaf)),
            ModelSpec(SceneObjectPlantSignalSumModel(); name=:plant_total) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(
                :signals => Many(
                    scale=:Leaf,
                    within=Self(),
                    process=:scene_object_signal_source,
                    var=:signal,
                ),
            ),
        );
        kind=:plant,
        species=:oil_palm,
        parameters=shared_template_parameters,
    )
    palm_1_leaf_override = SceneObjectParameterizedSignalModel(3.0)
    palm_1 = ObjectInstance(
        :palm_1,
        plant_template;
        root=Object(:templated_plant_1; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(
            Object(:templated_leaf_1; scale=:Leaf, parent=:templated_plant_1, status=Status(signal=0.0)),
            Object(:templated_leaf_1_exception; scale=:Leaf, parent=:templated_plant_1, status=Status(signal=0.0)),
        ),
        object_overrides=(
            Override(
                object=:templated_leaf_1_exception,
                application=:signal_source,
                model=palm_1_leaf_override,
            ),
        ),
    )
    palm_2_override = SceneObjectParameterizedSignalModel(2.0)
    palm_2 = ObjectInstance(
        :palm_2,
        plant_template;
        root=Object(:templated_plant_2; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(Object(:templated_leaf_2; scale=:Leaf, parent=:templated_plant_2, status=Status(signal=0.0)),),
        overrides=(scene_object_signal_source=palm_2_override,),
    )
    palm_3 = ObjectInstance(
        :palm_3,
        plant_template;
        root=Object(:templated_plant_3; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(Object(:templated_leaf_3; scale=:Leaf, parent=:templated_plant_3, status=Status(signal=0.0)),),
    )
    templated_plant_4 = Object(
        :templated_plant_4;
        scale=:Plant,
        parent=:scene,
        status=Status(signals=[0.0], signal_total=0.0),
    )
    templated_leaf_4 = Object(
        :templated_leaf_4;
        scale=:Leaf,
        parent=:templated_plant_4,
        status=Status(signal=0.0),
    )
    palm_4 = ObjectInstance(:palm_4, plant_template; root=:templated_plant_4)
    template_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        templated_plant_4,
        templated_leaf_4,
        palm_1,
        palm_2,
        palm_3;
        instances=(palm_4,),
    )
    @test length(template_scene.applications) == 8
    @test plant_template.parameters === shared_template_parameters
    @test only(scene_objects(template_scene; name=:palm_1)).id == ObjectId(:templated_plant_1)
    @test object_ids(template_scene; species=:oil_palm) == [
        ObjectId(:templated_leaf_1),
        ObjectId(:templated_leaf_1_exception),
        ObjectId(:templated_leaf_2),
        ObjectId(:templated_leaf_3),
        ObjectId(:templated_leaf_4),
        ObjectId(:templated_plant_1),
        ObjectId(:templated_plant_2),
        ObjectId(:templated_plant_3),
        ObjectId(:templated_plant_4),
    ]
    template_compiled = compile_scene(template_scene)
    template_application_rows = explain_scene_applications(template_compiled)
    @test only(row for row in template_application_rows if row.application_id == :palm_1__signal_source).target_ids ==
          [:templated_leaf_1, :templated_leaf_1_exception]
    @test only(row for row in template_application_rows if row.application_id == :palm_2__signal_source).target_ids ==
          [:templated_leaf_2]
    @test only(row for row in template_application_rows if row.application_id == :palm_3__plant_total).target_ids ==
          [:templated_plant_3]
    palm_1_signal_row = only(
        row for row in template_application_rows
        if row.application_id == :palm_1__signal_source
    )
    @test palm_1_signal_row.model_type == typeof(shared_signal_model)
    @test palm_1_signal_row.model_storage == :per_object_override
    @test palm_1_signal_row.model_dispatch == :concrete_per_object
    @test palm_1_signal_row.object_overrides == [
        (
            object_id=:templated_leaf_1_exception,
            model_type=typeof(palm_1_leaf_override),
        ),
    ]
    @test (@inferred PlantSimEngine._application_model(
        template_compiled.applications_by_id[:palm_1__signal_source],
        ObjectId(:templated_leaf_1),
    )) === shared_signal_model
    @test (@inferred PlantSimEngine._application_model(
        template_compiled.applications_by_id[:palm_1__signal_source],
        ObjectId(:templated_leaf_1_exception),
    )) === palm_1_leaf_override
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_3__signal_source].spec) === shared_signal_model
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_4__signal_source].spec) === shared_signal_model
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_2__signal_source].spec) === palm_2_override
    template_instance_rows = explain_instances(template_scene)
    palm_1_instance_row = only(row for row in template_instance_rows if row.name == :palm_1)
    @test palm_1_instance_row.root_id == :templated_plant_1
    @test palm_1_instance_row.object_ids ==
          [:templated_leaf_1, :templated_leaf_1_exception, :templated_plant_1]
    @test palm_1_instance_row.application_ids ==
          [:palm_1__plant_total, :palm_1__signal_source]
    @test palm_1_instance_row.object_overrides == [
        (
            object_id=:templated_leaf_1_exception,
            process=nothing,
            application=:signal_source,
            model_type=typeof(palm_1_leaf_override),
        ),
    ]
    @test palm_1_instance_row.parameters_shared_by_reference
    @test only(row for row in explain_objects(template_scene) if row.id == :templated_leaf_1).instance ==
          :palm_1
    run!(template_scene; steps=1)
    @test only(scene_objects(template_scene; name=:palm_1)).status.signal_total == 4.0
    @test only(scene_objects(template_scene; name=:palm_2)).status.signal_total == 2.0
    @test only(scene_objects(template_scene; name=:palm_3)).status.signal_total == 1.0
    @test only(scene_objects(template_scene; name=:palm_4)).status.signal_total == 1.0
    registered_template_leaf = register_object!(
        template_scene,
        Object(:templated_leaf_new; scale=:Leaf, status=Status(signal=0.0));
        parent=:templated_plant_2,
    )
    @test registered_template_leaf.kind == :plant
    @test registered_template_leaf.species == :oil_palm
    @test :templated_leaf_new in only(
        row.object_ids for row in explain_instances(template_scene)
        if row.name == :palm_2
    )
    refreshed_template = refresh_bindings!(template_scene)
    @test ObjectId(:templated_leaf_new) in
          refreshed_template.applications_by_id[:palm_2__signal_source].target_ids
    remove_object!(template_scene, :templated_leaf_new)
    @test_throws ErrorException Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            overrides=(missing_process=shared_signal_model,),
        ),
    )
    @test_throws ErrorException Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            overrides=(signal_source=Process1Model(1.0),),
        ),
    )
    @test_throws ErrorException Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant),),
            object_overrides=(
                Override(
                    object=:outside_instance,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    @test_throws ErrorException Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant),),
            object_overrides=(
                Override(
                    object=:invalid_leaf,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
                Override(
                    object=:invalid_leaf,
                    process=:scene_object_signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    unmatched_override_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant, status=Status(signal=0.0)),),
            object_overrides=(
                Override(
                    object=:invalid_plant,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    @test_throws ErrorException compile_scene(unmatched_override_scene)

    call_template = ObjectTemplate(
        (
            ModelSpec(shared_signal_model; name=:signal_source) |>
            AppliesTo(Many(scale=:Leaf)),
            ModelSpec(SceneObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:oil_palm,
    )
    call_override_model = SceneObjectParameterizedSignalModel(4.0)
    call_override_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :call_palm,
            call_template;
            root=Object(:call_plant; scale=:Plant, parent=:scene),
            objects=(
                Object(:call_leaf_1; scale=:Leaf, parent=:call_plant, status=Status(signal=0.0, called_signal=0.0)),
                Object(:call_leaf_2; scale=:Leaf, parent=:call_plant, status=Status(signal=0.0, called_signal=0.0)),
            ),
            object_overrides=(
                Override(
                    object=:call_leaf_2,
                    application=:signal_source,
                    model=call_override_model,
                ),
            ),
        ),
    )
    run!(call_override_scene)
    call_leaf_1 = only(object for object in scene_objects(call_override_scene; scale=:Leaf) if object.id == ObjectId(:call_leaf_1))
    call_leaf_2 = only(object for object in scene_objects(call_override_scene; scale=:Leaf) if object.id == ObjectId(:call_leaf_2))
    @test call_leaf_1.status.called_signal == 1.0
    @test call_leaf_2.status.called_signal == 4.0

    leaf_selector = Many(
        kind="plant",
        scale=:Leaf,
        within=Self(),
        process="leaf_state",
        var="leaf_area",
        policy=Integrate(),
        window=Day(1),
    )

    @test leaf_selector.criteria.kind == :plant
    @test leaf_selector.criteria.scale == :Leaf
    @test leaf_selector.criteria.within isa Self
    @test leaf_selector.criteria.process == :leaf_state
    @test leaf_selector.criteria.var == :leaf_area
    @test leaf_selector.criteria.policy isa Integrate
    @test leaf_selector.criteria.window == Day(1)

    address = object_address(leaf_selector)
    @test address.scope isa Self
    @test address.kind == :plant
    @test address.scale == :Leaf
    @test address.process == :leaf_state
    @test address.var == :leaf_area
    @test address.multiplicity == :many

    @test One(Kind(:plant), Scale(:Leaf)).criteria.selectors == (Kind(:plant), Scale(:Leaf))
    @test object_address(OptionalOne(scale=:Scene)).multiplicity == :optional_one

    default_input = Input(Many(scale=:Leaf, within=Self(), var=:leaf_carbon))
    @test default_input.selector isa Many
    @test default_input.selector.criteria.within isa Self

    default_call = Call(process=:stomatal_conductance)
    @test default_call.selector isa One
    @test object_address(default_call.selector).process == :stomatal_conductance

    m = Process1Model(1.0)
    spec = ModelSpec(m; name=:leaf_energy) |>
           AppliesTo(Many(kind=:plant, scale=:Leaf)) |>
           Inputs(
               :leaf_areas => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_area),
               :leaf_carbon => Many(scale=:Leaf, within=Self(), var=:leaf_carbon, policy=Integrate(), window=Day(1)),
           ) |>
           Calls(:stomata => One(scale=:Leaf, process=:stomatal_conductance)) |>
           TimeStep(Hour(1)) |>
           Environment(provider=:global)

    @test PlantSimEngine.model_(spec) === m
    @test application_name(spec) == :leaf_energy
    @test applies_to(spec) isa Many
    @test applies_to(spec).criteria.kind == :plant
    @test value_inputs(spec).leaf_areas isa Many
    @test value_inputs(spec).leaf_carbon.criteria.policy isa Integrate
    @test value_inputs(spec).leaf_carbon.criteria.window == Day(1)
    @test model_calls(spec).stomata isa One
    @test object_address(model_calls(spec).stomata).process == :stomatal_conductance
    call_dep = dep(spec).stomata
    @test call_dep isa HardDomains
    @test call_dep.scale == :Leaf
    @test call_dep.process == :stomatal_conductance
    @test PlantSimEngine.timestep(spec) == Hour(1)
    @test environment_config(spec) isa PlantSimEngine.EnvironmentConfig
    @test environment_config(spec).config.provider == :global

    # The old multirate metadata stays available while the compiler is migrated.
    legacy_and_unified = spec |>
                         InputBindings(; var1=(process=:process1, var=:var3)) |>
                         OutputRouting(; var3=:stream_only) |>
                         ScopeModel(:plant) |>
                         Updates(:var3; after=:process1)
    @test input_bindings(legacy_and_unified).var1.process == :process1
    @test output_routing(legacy_and_unified).var3 == :stream_only
    @test model_scope(legacy_and_unified) == :plant
    @test updates(legacy_and_unified)[1].after == (:process1,)
    @test value_inputs(legacy_and_unified) == value_inputs(spec)
    @test model_calls(legacy_and_unified) == model_calls(spec)

    rows = explain_model_specs(Dict(:Leaf => (spec,)); io=IOBuffer())
    @test length(rows) == 1
    @test rows[1].application_name == :leaf_energy
    @test rows[1].applies_to === applies_to(spec)
    @test rows[1].value_inputs == value_inputs(spec)
    @test rows[1].model_calls == model_calls(spec)
    @test rows[1].environment === environment_config(spec)

    leaf_assim = ModelSpec(ToyAssimModel()) |>
                 AppliesTo(Many(scale=:Leaf)) |>
                 Inputs(:soil_water_content => One(scale=:Soil, var=:soil_water_content))
    @test length(PlantSimEngine.get_mapped_variables(leaf_assim)) == 1

    mapping = Dict(
        :Leaf => (leaf_assim,),
        :Soil => (ToySoilWaterModel(),),
    )
    resolved = resolved_model_specs(mapping)
    binding = input_bindings(resolved[:Leaf][:carbon_assimilation]).soil_water_content
    @test binding.scale == :Soil
    @test binding.var == :soil_water_content
    @test binding.process == :soil_water

    rich_selector_spec = ModelSpec(ToyAssimModel()) |>
                         Inputs(:soil_water_content => One(kind=:soil, scale=:Soil, var=:soil_water_content))
    @test isempty(PlantSimEngine.get_mapped_variables(rich_selector_spec))
    @test value_inputs(rich_selector_spec).soil_water_content.criteria.kind == :soil

    default_input_spec = ModelSpec(SceneObjectDefaultInputConsumerModel())
    @test value_inputs(default_input_spec).leaf_carbon isa Many
    @test value_inputs(default_input_spec).leaf_carbon.criteria.within isa Self
    @test !haskey(dep(default_input_spec), :leaf_carbon)
    @test length(PlantSimEngine.get_mapped_variables(default_input_spec)) == 1

    override_input_spec = ModelSpec(SceneObjectDefaultInputConsumerModel()) |>
                          Inputs(:leaf_carbon => Many(scale=:Leaf, var=:carbon_override))
    @test value_inputs(override_input_spec).leaf_carbon.criteria.var == :carbon_override
    mapped = only(PlantSimEngine.get_mapped_variables(override_input_spec))
    @test first(mapped) == :leaf_carbon
    @test last(mapped) == [:Leaf => :carbon_override]

    default_call_spec = ModelSpec(SceneObjectDefaultCallConsumerModel())
    @test model_calls(default_call_spec).stomata isa One
    @test model_calls(default_call_spec).stomata.criteria.scale == :Leaf
    @test model_calls(default_call_spec).stomata.criteria.process == :stomatal_conductance
    default_call_dep = dep(default_call_spec).stomata
    @test default_call_dep isa HardDomains
    @test default_call_dep.scale == :Leaf
    @test default_call_dep.process == :stomatal_conductance

    override_call_spec = ModelSpec(SceneObjectDefaultCallConsumerModel()) |>
                         Calls(:stomata => One(scale=:Internode, process=:water_status))
    @test model_calls(override_call_spec).stomata.criteria.scale == :Internode
    @test model_calls(override_call_spec).stomata.criteria.process == :water_status
    override_call_dep = dep(override_call_spec).stomata
    @test override_call_dep isa HardDomains
    @test override_call_dep.scale == :Internode
    @test override_call_dep.process == :water_status

    compiled_specs = (
        ModelSpec(SceneObjectStomataModel(); name=:stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(SceneObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area, policy=Integrate(), window=Day(1))),
    )
    compiled = compile_scene(selector_scene, compiled_specs)
    application_rows = explain_scene_applications(compiled)
    @test length(application_rows) == 2
    @test only(row for row in application_rows if row.application_id == :stomata).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]
    @test only(row for row in application_rows if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]

    binding_rows = explain_bindings(compiled)
    @test length(binding_rows) == 3
    leaf_2_binding = only(row for row in binding_rows if row.consumer_id == :leaf_2)
    @test leaf_2_binding.application_id == :leaf_energy
    @test leaf_2_binding.input == :leaf_areas
    @test leaf_2_binding.source_ids == [:leaf_1, :leaf_2]
    @test leaf_2_binding.source_var == :leaf_area
    @test leaf_2_binding.carrier_hint == :temporal_stream
    @test leaf_2_binding.carrier_kind == :temporal_stream
    @test leaf_2_binding.copy_semantics == :materialized_temporal_value

    call_rows = explain_calls(compiled)
    @test length(call_rows) == 3
    leaf_2_call = only(row for row in call_rows if row.consumer_id == :leaf_2)
    @test leaf_2_call.application_id == :leaf_energy
    @test leaf_2_call.call == :stomata
    @test leaf_2_call.callee_object_ids == [:leaf_2]
    @test leaf_2_call.callee_application_ids == [:stomata]
    @test leaf_2_call.process == :scene_object_stomata

    ambiguous_call_specs = (
        ModelSpec(SceneObjectStomataModel(); name=:sunlit_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(SceneObjectStomataModel(); name=:shaded_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(SceneObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)),
    )
    @test_throws ErrorException compile_scene(selector_scene, ambiguous_call_specs)

    disambiguated_call_specs = (
        ModelSpec(SceneObjectStomataModel(); name=:sunlit_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(SceneObjectStomataModel(); name=:shaded_stomata) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Updates(:gs; after=:sunlit_stomata),
        ModelSpec(SceneObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area)) |>
        Calls(:stomata => One(process=:scene_object_stomata, application=:sunlit_stomata)),
    )
    disambiguated = compile_scene(selector_scene, disambiguated_call_specs)
    disambiguated_call = only(row for row in explain_calls(disambiguated) if row.consumer_id == :leaf_2)
    @test disambiguated_call.callee_application_ids == [:sunlit_stomata]
    @test disambiguated_call.application == :sunlit_stomata
    leaf_2_call_bindings = disambiguated.call_bindings_by_target[(:leaf_energy, ObjectId(:leaf_2))]
    @test length(leaf_2_call_bindings) == 1
    @test only(leaf_2_call_bindings).call == :stomata

    default_scope_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=1.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=2.0)),
        Object(:plant_2; scale=:Plant, kind=:plant, parent=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_3; scale=:Leaf, kind=:plant, parent=:plant_2, status=Status(leaf_area=3.0)),
    )
    plant_default_scope = compile_scene(
        default_scope_scene,
        (
            ModelSpec(SceneObjectTemporalSumModel(); name=:plant_leaf_sum) |>
            AppliesTo(Many(scale=:Plant)) |>
            Inputs(:signal_sum => Many(scale=:Leaf, var=:leaf_area)),
        ),
    )
    @test only(row for row in explain_bindings(plant_default_scope) if row.consumer_id == :plant_1).source_ids ==
          [:leaf_1, :leaf_2]
    @test only(row for row in explain_bindings(plant_default_scope) if row.consumer_id == :plant_2).source_ids ==
          [:leaf_3]
    scene_default_scope = compile_scene(
        default_scope_scene,
        (
            ModelSpec(SceneObjectTemporalSumModel(); name=:scene_leaf_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => Many(scale=:Leaf, var=:leaf_area)),
        ),
    )
    @test only(explain_bindings(scene_default_scope)).source_ids == [:leaf_1, :leaf_2, :leaf_3]

    inferred_input_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0)),
    )
    inferred_input_specs = (
        ModelSpec(SceneObjectSignalSourceModel(); name=:signal_source) |>
        AppliesTo(One(scale=:Leaf)),
        ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
        AppliesTo(One(scale=:Leaf)),
    )
    inferred_compiled = compile_scene(inferred_input_scene, inferred_input_specs)
    inferred_binding = only(explain_bindings(inferred_compiled))
    @test inferred_binding.application_id == :signal_consumer
    @test inferred_binding.input == :signal
    @test inferred_binding.origin == :inferred_same_object
    @test inferred_binding.source_ids == [:leaf_1]
    @test inferred_binding.source_application_ids == [:signal_source]
    @test inferred_binding.process == :scene_object_signal_source
    @test inferred_binding.application == :signal_source
    @test inferred_binding.has_reference_carrier
    @test inferred_binding.carrier_kind == :ref
    @test inferred_binding.copy_semantics == :live_references
    inferred_input_scene_with_apps = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0));
        applications=inferred_input_specs,
    )
    run!(inferred_input_scene_with_apps)
    @test only(scene_objects(inferred_input_scene_with_apps; scale=:Leaf)).status.observed_signal == 1.0

    reversed_dependency_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0));
        applications=reverse(inferred_input_specs),
    )
    reversed_compiled = refresh_bindings!(reversed_dependency_scene)
    @test length(reversed_compiled.applications_by_id) == length(reversed_compiled.applications)
    @test reversed_compiled.applications_by_id[:signal_source].process == :scene_object_signal_source
    @test reversed_compiled.applications_by_id[:signal_consumer].process == :scene_object_signal_consumer
    @test reversed_compiled.application_order == [:signal_source, :signal_consumer]
    @test [row.application_id for row in explain_schedule(reversed_compiled)] ==
          [:signal_source, :signal_consumer]
    @test [row.execution_index for row in explain_schedule(reversed_compiled)] == [1, 2]
    run!(reversed_dependency_scene)
    @test only(scene_objects(reversed_dependency_scene; scale=:Leaf)).status.observed_signal == 1.0

    @test_throws ErrorException compile_scene(
        Scene(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(cycle_a=0.0, cycle_b=0.0)),
        ),
        (
            ModelSpec(SceneObjectCycleAModel(); name=:cycle_a) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(SceneObjectCycleBModel(); name=:cycle_b) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )

    @test_throws ErrorException compile_scene(
        Scene(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(observed_signal=0.0)),
        ),
        (
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    @test_throws ErrorException compile_scene(
        inferred_input_scene,
        (
            ModelSpec(SceneObjectSignalSourceModel(); name=:sunlit_signal) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(SceneObjectSignalSourceModel(); name=:shaded_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            Updates(:signal; after=:sunlit_signal),
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )

    filtered_input_specs = (
        ModelSpec(SceneObjectSignalSourceModel(); name=:signal_source) |>
        AppliesTo(One(scale=:Leaf)),
        ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
        AppliesTo(One(scale=:Leaf)) |>
        Inputs(:signal => One(scale=:Leaf, var=:signal, process=:scene_object_signal_source, application=:signal_source)),
    )
    filtered_binding = only(explain_bindings(compile_scene(inferred_input_scene, filtered_input_specs)))
    @test filtered_binding.origin == :declared
    @test filtered_binding.source_application_ids == [:signal_source]
    @test filtered_binding.process == :scene_object_signal_source
    @test filtered_binding.application == :signal_source
    @test_throws ErrorException compile_scene(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:signal => One(scale=:Leaf, var=:signal, application=:missing_source)),
        ),
    )
    @test_throws ErrorException compile_scene(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:siggnal => One(scale=:Leaf, var=:signal, application=:signal_source)),
        ),
    )
    @test_throws ErrorException compile_scene(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:signal => One(scale=:Leaf, var=:missing_signal)),
        ),
    )

    carrier_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, status=Status(leaf_area=1.0, leaf_token=SceneObjectTaggedValue(1), aPPFD=100.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, status=Status(leaf_area=2.0, leaf_token=2, aPPFD=100.0)),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene, status=Status(soil_water_content=0.31)),
    )
    carrier_specs = (
        ModelSpec(SceneObjectCarrierConsumerModel(); name=:carrier_consumer) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(
            :leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area),
            :leaf_tokens => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_token),
        ),
        ModelSpec(ToyAssimModel(); name=:assim) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:soil_water_content => One(scale=:Soil, within=SceneScope(), var=:soil_water_content)),
    )
    carrier_compiled = compile_scene(carrier_scene, carrier_specs)
    carrier_rows = explain_bindings(carrier_compiled)
    leaf_1_carrier_bindings = carrier_compiled.input_bindings_by_target[(:carrier_consumer, ObjectId(:leaf_1))]
    @test length(leaf_1_carrier_bindings) == 2
    @test Set(binding.input for binding in leaf_1_carrier_bindings) == Set((:leaf_areas, :leaf_tokens))
    @test length(carrier_compiled.input_bindings_by_target[(:assim, ObjectId(:leaf_1))]) == 1
    leaf_area_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :carrier_consumer && binding.consumer_id == ObjectId(:leaf_1) && binding.input == :leaf_areas
    )
    @test has_reference_carrier(leaf_area_binding)
    @test input_carrier(leaf_area_binding) isa PlantSimEngine.RefVector
    @test input_value(leaf_area_binding)[1] == 1.0
    input_value(leaf_area_binding)[1] = 4.0
    leaf_1_object = only(object for object in scene_objects(carrier_scene; scale=:Leaf) if object.id == ObjectId(:leaf_1))
    @test leaf_1_object.status.leaf_area == 4.0
    leaf_area_row = only(row for row in carrier_rows if row.application_id == :carrier_consumer && row.consumer_id == :leaf_1 && row.input == :leaf_areas)
    @test leaf_area_row.has_reference_carrier
    @test leaf_area_row.carrier_kind == :ref_vector
    @test leaf_area_row.copy_semantics == :live_references

    token_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :carrier_consumer && binding.consumer_id == ObjectId(:leaf_1) && binding.input == :leaf_tokens
    )
    @test input_value(token_binding)[2] == 2
    input_value(token_binding)[2] = 20
    leaf_2_object = only(object for object in scene_objects(carrier_scene; scale=:Leaf) if object.id == ObjectId(:leaf_2))
    @test leaf_2_object.status.leaf_token == 20
    token_row = only(row for row in carrier_rows if row.application_id == :carrier_consumer && row.consumer_id == :leaf_1 && row.input == :leaf_tokens)
    @test token_row.carrier_kind == :object_ref_vector
    @test token_row.copy_semantics == :live_references

    scalar_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :assim && binding.consumer_id == ObjectId(:leaf_1)
    )
    @test has_reference_carrier(scalar_binding)
    @test input_carrier(scalar_binding) isa Base.RefValue
    @test input_value(scalar_binding) == 0.31
    input_carrier(scalar_binding)[] = 0.42
    @test only(scene_objects(carrier_scene; scale=:Soil)).status.soil_water_content == 0.42
    scalar_row = only(row for row in carrier_rows if row.application_id == :assim && row.consumer_id == :leaf_1)
    @test scalar_row.carrier_kind == :ref
    @test scalar_row.copy_semantics == :live_references

    cache_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:axis_1),
        Object(:plant_2; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_2, parent=:scene),
        Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_2),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene);
        applications=compiled_specs,
    )
    @test bindings_dirty(cache_scene)
    cached_a = refresh_bindings!(cache_scene)
    @test cached_a isa CompiledScene
    @test !bindings_dirty(cache_scene)
    @test compiled_bindings(cache_scene) === cached_a
    @test cached_a.revision == scene_revision(cache_scene)
    @test refresh_bindings!(cache_scene) === cached_a

    register_object!(cache_scene, Object(:leaf_4; scale=:Leaf, kind=:plant, species=:oil_palm); parent=:plant_2)
    @test bindings_dirty(cache_scene)
    @test isnothing(compiled_bindings(cache_scene))
    cached_b = refresh_bindings!(cache_scene)
    @test cached_b !== cached_a
    @test cached_b.revision == scene_revision(cache_scene)
    @test only(row for row in explain_scene_applications(cached_b) if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3, :leaf_4]
    @test only(row for row in explain_bindings(cached_b) if row.consumer_id == :leaf_3).source_ids ==
          [:leaf_3, :leaf_4]

    move_object!(cache_scene, :leaf_4, (x=3.0, y=0.0))
    @test !bindings_dirty(cache_scene)
    @test environment_bindings_dirty(cache_scene)
    @test refresh_bindings!(cache_scene) === cached_b
    mark_environment_binding_dirty!(cache_scene)
    @test !bindings_dirty(cache_scene)

    reparent_object!(cache_scene, :leaf_4, :plant_1)
    cached_c = refresh_bindings!(cache_scene)
    @test only(row for row in explain_bindings(cached_c) if row.consumer_id == :leaf_4).source_ids ==
          [:leaf_1, :leaf_2, :leaf_4]

    remove_object!(cache_scene, :leaf_4)
    cached_d = refresh_bindings!(cache_scene)
    @test only(row for row in explain_scene_applications(cached_d) if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]

    grid_backend = SceneObjectGridBackend(Any[])
    environment_specs = (
        ModelSpec(SceneObjectEnvironmentProbeModel(); name=:probe) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Environment(provider=:grid),
        ModelSpec(SceneObjectEnvironmentUpdateModel(); name=:temperature_update) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Environment(provider=:grid),
    )
    environment_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(cell=:cell_a,)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(cell=:cell_b,));
        applications=environment_specs,
        environment=grid_backend,
    )
    compiled_environment = refresh_environment_bindings!(environment_scene)
    @test compiled_environment isa CompiledEnvironmentBindings
    @test !environment_bindings_dirty(environment_scene)
    @test compiled_environment_bindings(environment_scene) === compiled_environment
    @test length(compiled_environment.by_target) == length(compiled_environment.bindings)
    @test compiled_environment.by_target[(:probe, ObjectId(:leaf_1))].cell == :cell_a
    @test compiled_environment.by_target[(:temperature_update, ObjectId(:leaf_2))].cell == :cell_b
    @test length(grid_backend.index_updates) == 1
    @test any(entity -> entity.id == :leaf_1 && entity.geometry == (cell=:cell_a,), grid_backend.index_updates[1])
    @test any(entity -> entity.id == :plant_1 && entity.scale == :Plant, grid_backend.index_updates[1])
    environment_rows = explain_environment_bindings(compiled_environment)
    @test length(environment_rows) == 4
    leaf_1_probe = only(row for row in environment_rows if row.application_id == :probe && row.object_id == :leaf_1)
    @test leaf_1_probe.provider == :grid
    @test leaf_1_probe.cell == :cell_a
    @test leaf_1_probe.required_inputs == [:T, :CO2]
    @test leaf_1_probe.produced_outputs == Symbol[]
    leaf_2_update = only(row for row in environment_rows if row.application_id == :temperature_update && row.object_id == :leaf_2)
    @test leaf_2_update.cell == :cell_b
    @test leaf_2_update.required_inputs == [:T]
    @test leaf_2_update.produced_outputs == [:T]

    structural_environment_cache = refresh_bindings!(environment_scene)
    move_object!(environment_scene, :leaf_2, (cell=:cell_c,))
    @test !bindings_dirty(environment_scene)
    @test environment_bindings_dirty(environment_scene)
    @test refresh_bindings!(environment_scene) === structural_environment_cache
    refreshed_environment = refresh_environment_bindings!(environment_scene)
    @test !environment_bindings_dirty(environment_scene)
    @test length(grid_backend.index_updates) == 2
    @test any(entity -> entity.id == :leaf_2 && entity.geometry == (cell=:cell_c,), grid_backend.index_updates[2])
    @test only(row for row in explain_environment_bindings(refreshed_environment) if row.application_id == :probe && row.object_id == :leaf_2).cell == :cell_c

    update_geometry!(environment_scene, :leaf_1, (cell=:cell_e,); invalidate_environment=false)
    @test geometry(only(object for object in scene_objects(environment_scene; scale=:Leaf) if object.id == ObjectId(:leaf_1))) == (cell=:cell_e,)
    @test !environment_bindings_dirty(environment_scene)
    mark_environment_binding_dirty!(environment_scene, :leaf_1)
    @test environment_bindings_dirty(environment_scene)
    refreshed_after_mark = refresh_environment_bindings!(environment_scene)
    @test !environment_bindings_dirty(environment_scene)
    @test length(grid_backend.index_updates) == 3
    @test any(entity -> entity.id == :leaf_1 && entity.geometry == (cell=:cell_e,), grid_backend.index_updates[3])
    @test only(row for row in explain_environment_bindings(refreshed_after_mark) if row.application_id == :probe && row.object_id == :leaf_1).cell == :cell_e

    register_object!(environment_scene, Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, geometry=(cell=:cell_d,)); parent=:plant_1)
    @test bindings_dirty(environment_scene)
    @test environment_bindings_dirty(environment_scene)
    refreshed_with_new_leaf = refresh_environment_bindings!(environment_scene)
    @test length(grid_backend.index_updates) == 4
    @test any(entity -> entity.id == :leaf_3 && entity.geometry == (cell=:cell_d,), grid_backend.index_updates[4])
    @test only(row for row in explain_scene_applications(refresh_bindings!(environment_scene)) if row.application_id == :probe).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]
    @test only(row for row in explain_environment_bindings(refreshed_with_new_leaf) if row.application_id == :probe && row.object_id == :leaf_3).cell == :cell_d

    mutable_environment_backend = SceneObjectMutableEnvironmentBackend(:cell_a => 20.0, :cell_b => 30.0)
    mutable_environment_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, geometry=(cell=:cell_a,), status=Status(T=0.0, temperature_update=0.0, temperature_seen=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:scene, geometry=(cell=:cell_b,), status=Status(T=0.0, temperature_update=0.0, temperature_seen=0.0));
        applications=(
            ModelSpec(SceneObjectEnvironmentUpdateModel(); name=:temperature_update_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(SceneObjectEnvironmentProbeModel(); name=:probe_after_update) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
        environment=mutable_environment_backend,
    )
    run!(mutable_environment_scene)
    @test mutable_environment_backend.values == Dict(:cell_a => 21.0, :cell_b => 31.0)
    @test mutable_environment_backend.writes == [
        (application=:temperature_update_runtime, process=:scene_object_environment_update, cell=:cell_a, variable=:T, value=21.0, time=1),
        (application=:temperature_update_runtime, process=:scene_object_environment_update, cell=:cell_b, variable=:T, value=31.0, time=1),
    ]
    mutable_environment_statuses = Dict(object.id.value => object.status for object in scene_objects(mutable_environment_scene; scale=:Leaf))
    @test mutable_environment_statuses[:leaf_1].temperature_seen == 21.0
    @test mutable_environment_statuses[:leaf_2].temperature_seen == 31.0

    runtime_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=1.5, leaf_areas=[0.0], leaf_tokens=Any[], carrier_total=0.0, temperature_seen=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=2.5, leaf_areas=[0.0], leaf_tokens=Any[], carrier_total=0.0, temperature_seen=0.0));
        applications=(
            ModelSpec(SceneObjectCarrierConsumerModel(); name=:carrier_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area)),
            ModelSpec(SceneObjectEnvironmentProbeModel(); name=:probe_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:global),
        ),
        environment=(T=27.5, CO2=410.0),
    )
    run!(runtime_scene)
    @test all(object.status.carrier_total == 4.0 for object in scene_objects(runtime_scene; scale=:Leaf))
    @test all(object.status.temperature_seen == 27.5 for object in scene_objects(runtime_scene; scale=:Leaf))

    call_runtime_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, called_signal=0.0));
        applications=(
            ModelSpec(SceneObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(SceneObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    run!(call_runtime_scene)
    call_status = only(scene_objects(call_runtime_scene; scale=:Leaf)).status
    @test call_status.signal == 1.0
    @test call_status.called_signal == 1.0
    call_schedule = explain_schedule(refresh_bindings!(call_runtime_scene))
    @test only(row for row in call_schedule if row.application_id == :signal_source).manual_call_only
    @test !only(row for row in call_schedule if row.application_id == :signal_source).root_scheduled
    @test only(row for row in call_schedule if row.application_id == :signal_caller).root_scheduled

    hard_call_order_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, called_signal=0.0, observed_signal=0.0));
        applications=(
            ModelSpec(SceneObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(SceneObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(SceneObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    hard_call_order = refresh_bindings!(hard_call_order_scene)
    @test hard_call_order.applications_by_id[:signal_caller].process == :scene_object_signal_caller
    @test hard_call_order.application_order == [:signal_source, :signal_caller, :signal_consumer]
    run!(hard_call_order_scene)
    hard_call_order_status = only(scene_objects(hard_call_order_scene; scale=:Leaf)).status
    @test hard_call_order_status.signal == 1.0
    @test hard_call_order_status.observed_signal == 1.0

    temporal_input_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(SceneObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(SceneObjectTemporalSumModel(); name=:scene_temporal_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal, policy=Integrate(), window=Hour(2))) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    temporal_binding = only(
        row for row in explain_bindings(refresh_bindings!(temporal_input_scene))
        if row.application_id == :scene_temporal_sum && row.input == :signal_sum
    )
    @test temporal_binding.carrier_hint == :temporal_stream
    run!(temporal_input_scene; steps=3)
    @test only(scene_objects(temporal_input_scene; scale=:Leaf)).status.signal == 3.0
    @test only(scene_objects(temporal_input_scene; scale=:Scene)).status.temporal_total == 5.0

    temporal_holdlast_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(SceneObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(SceneObjectTemporalSumModel(); name=:scene_temporal_latest) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal, policy=HoldLast(), window=Hour(2))) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    run!(temporal_holdlast_scene; steps=3)
    @test only(scene_objects(temporal_holdlast_scene; scale=:Scene)).status.temporal_total == 3.0

    writer_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(biomass=-1.0)),
    )
    biomass_source =
        ModelSpec(SceneObjectBiomassSourceModel(); name=:carbon_allocation) |>
        AppliesTo(One(scale=:Leaf))
    biomass_pruner =
        ModelSpec(SceneObjectBiomassPrunerModel(); name=:leaf_pruning) |>
        AppliesTo(One(scale=:Leaf))

    @test_throws ErrorException compile_scene(writer_scene, (biomass_source, biomass_pruner))
    @test_throws ErrorException compile_scene(
        writer_scene,
        (biomass_source, biomass_pruner |> Updates(:biomass; after=:water_status)),
    )
    @test_throws ErrorException compile_scene(
        writer_scene,
        (biomass_pruner |> Updates(:biomass; after=:carbon_allocation), biomass_source),
    )

    ordered_pruner = biomass_pruner |> Updates(:biomass; after=:carbon_allocation)
    writer_compiled = compile_scene(writer_scene, (biomass_source, ordered_pruner))
    writer_row = only(row for row in explain_writers(writer_compiled) if row.variable == :biomass)
    @test writer_row.object_id == :leaf_1
    @test writer_row.duplicate
    @test writer_row.application_ids == [:carbon_allocation, :leaf_pruning]
    @test writer_row.update_application_ids == [:leaf_pruning]
    @test writer_row.update_after == [:leaf_pruning => [:carbon_allocation]]

    writer_runtime_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(biomass=-1.0));
        applications=(biomass_source, ordered_pruner),
    )
    run!(writer_runtime_scene)
    @test only(scene_objects(writer_runtime_scene; scale=:Leaf)).status.biomass == 0.0

    multirate_scene = Scene(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(SceneObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    multirate_compiled = refresh_bindings!(multirate_scene)
    schedule_rows = explain_schedule(multirate_compiled)
    @test only(schedule_rows).application_id == :hourly_signal
    @test only(schedule_rows).dt_steps == 2.0
    @test only(schedule_rows).dt_seconds == 7200.0
    run!(multirate_scene; steps=5)
    @test only(scene_objects(multirate_scene; scale=:Leaf)).status.signal == 3.0
end
