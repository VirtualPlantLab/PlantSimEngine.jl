using PlantSimEngine
using PlantSimEngine.Diagnostics
using PlantSimEngine.GraphEditor
using Test

# This oracle deliberately scans objects and walks parent links. It must not use
# registry label indexes, compiled matchers, or the optimized selector resolver.
function adaptive_reference_subtree(model, id, root)
    current = ObjectId(id)
    while true
        current == ObjectId(root) && return true
        parent = model_object(model, current).parent
        isnothing(parent) && return false
        current = parent
    end
end

function adaptive_reference_label(value, requested)
    isnothing(requested) && return true
    requested isa Union{Tuple,AbstractVector} && return value in requested
    return value == requested
end

function adaptive_reference_ids(
    model;
    root=nothing,
    context=nothing,
    relation=nothing,
    scale=nothing,
    kind=nothing,
    species=nothing,
    id=nothing,
)
    requested_ids = isnothing(id) ? nothing :
                    id isa Union{Tuple,AbstractVector} ? ObjectId.(id) : ObjectId(id)
    context_id = isnothing(context) ? nothing : ObjectId(context)
    ids = ObjectId[]
    for object in values(model.registry.objects)
        adaptive_reference_label(object.scale, scale) || continue
        adaptive_reference_label(object.kind, kind) || continue
        adaptive_reference_label(object.species, species) || continue
        adaptive_reference_label(object.id, requested_ids) || continue
        isnothing(root) || adaptive_reference_subtree(model, object.id, root) || continue
        if !isnothing(relation)
            current = model_object(model, context_id)
            matches = if relation == :self
                object.id == context_id
            elseif relation == :parent
                object.id == current.parent
            elseif relation == :children
                object.parent == context_id
            elseif relation == :ancestors
                object.id != context_id &&
                    adaptive_reference_subtree(model, context_id, object.id)
            elseif relation == :descendants
                object.id != context_id &&
                    adaptive_reference_subtree(model, object.id, context_id)
            elseif relation == :siblings
                object.id != context_id && !isnothing(current.parent) &&
                    object.parent == current.parent
            else
                error("Unsupported reference relation")
            end
            matches || continue
        end
        push!(ids, object.id)
    end
    # All fixture IDs are symbols, whose specified natural ordering is stable.
    return sort!(ids; by=id -> id.value)
end

function adaptive_selector_scene()
    objects = Object[Object(:scene; scale=:Scene, kind=:scene)]
    for plant in 1:8
        plant_id = Symbol(:plant_, plant)
        axis_id = Symbol(:axis_, plant)
        push!(objects, Object(plant_id; scale=:Plant, kind=:plant, parent=:scene))
        push!(objects, Object(axis_id; scale=:Axis, kind=:axis, parent=plant_id))
        for leaf in 1:72
            push!(objects, Object(
                Symbol(:leaf_, plant, :_, leaf);
                scale=:Leaf,
                kind=isodd(leaf) ? :active : :dormant,
                species=leaf % 3 == 0 ? :alternate : :common,
                parent=isodd(leaf) ? plant_id : axis_id,
            ))
        end
    end
    push!(objects, Object(:nested_plant; scale=:Plant, kind=:plant, parent=:plant_1))
    push!(objects, Object(:nested_leaf; scale=:Leaf, kind=:active, species=:common,
        parent=:nested_plant))
    push!(objects, Object(:unlabelled; parent=:plant_1))
    push!(objects, Object(:unlabelled_leaf; scale=:Leaf, parent=:plant_1))
    push!(objects, Object(:large; scale=:Plant, kind=:plant, parent=:scene))
    for leaf in 1:1024
        push!(objects, Object(
            Symbol(:large_leaf_, leaf);
            scale=:Leaf,
            kind=:active,
            species=leaf in (2, 512, 1024) ? :rare : :common,
            parent=:large,
        ))
    end
    return CompositeModel(objects...)
end

@testset "adaptive selector IDs and deterministic ordering" begin
    model = adaptive_selector_scene()
    for plant in 1:8
        context = Symbol(:plant_, plant)
        for labels in (
            (scale=:Leaf,),
            (scale=:Leaf, kind=:active),
            (scale=(:Leaf, :Axis), kind=(:active, :axis), species=(:common, :alternate)),
            (scale=[:Leaf, :Leaf], kind=[:active, :dormant]),
            (scale=:Leaf, species=:missing),
            (scale=(),),
            (scale=:Leaf, species=(:missing, :common, :common)),
            (species=(nothing, :common),),
            (scale=(nothing, :Leaf), species=(nothing, :common)),
            (scale=:Leaf, kind=(nothing, :active)),
            (scale=(nothing, :Leaf),),
        )
            normalized = (; (key => (value isa AbstractVector ? Tuple(value) : value)
                              for (key, value) in pairs(labels))...)
            @test resolve_object_ids(model, Many(Subtree(); labels...); context) ==
                  adaptive_reference_ids(model; root=context, normalized...)
            @test resolve_object_ids(model, Many(Relation(:descendants); labels...); context) ==
                  adaptive_reference_ids(model; context, relation=:descendants, normalized...)
        end
    end

    for species in (:rare, :common, :missing, (:rare, :missing))
        @test resolve_object_ids(model, Many(Subtree(); scale=:Leaf, species); context=:large) ==
              adaptive_reference_ids(model; root=:large, scale=:Leaf, species)
        @test resolve_object_ids(model, Many(Scope(:large); scale=:Leaf, species)) ==
              adaptive_reference_ids(model; root=:large, scale=:Leaf, species)
    end
    @test object_ids(model; scale=(nothing, :Leaf)) ==
          adaptive_reference_ids(model; scale=(nothing, :Leaf))
    for selector in (Many(), Many(SceneScope()), Many(Subtree()))
        context = selector isa Many && any(x -> x isa Subtree, selector.criteria.selectors) ?
                  :plant_1 : nothing
        @test resolve_object_ids(model, selector; context) ==
              adaptive_reference_ids(model; root=context)
    end
    @test resolve_object_ids(model, Many(Subtree(); id=(:leaf_1_2, :missing, :leaf_1_1,
        :leaf_1_2, :leaf_2_1)); context=:plant_1) ==
          adaptive_reference_ids(model; root=:plant_1,
              id=(:leaf_1_2, :missing, :leaf_1_1, :leaf_1_2, :leaf_2_1))
    @test resolve_object_ids(model, Many(Subtree(); id=:missing); context=:plant_1) == ObjectId[]
    @test resolve_object_ids(model, Many(Subtree(); id=()); context=:plant_1) == ObjectId[]

    mixed_ids = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(10; scale=:Leaf, parent=:scene),
        Object(2; scale=:Leaf, parent=:scene),
        Object(Symbol("2"); scale=:Leaf, parent=:scene),
    )
    @test resolve_object_ids(mixed_ids, Many(Subtree(); scale=:Leaf); context=:scene) ==
          ObjectId[ObjectId(2), ObjectId(10), ObjectId(Symbol("2"))]
    @test resolve_object_ids(mixed_ids, Many(Subtree(); id=(Symbol("2"), 10, 2, 2));
        context=:scene) == ObjectId[ObjectId(2), ObjectId(10), ObjectId(Symbol("2"))]

    # None of the resolver paths may mutate their source label buckets.
    original_indexes = deepcopy((model.registry.by_scale, model.registry.by_kind,
        model.registry.by_species))
    resolve_object_ids(model, Many(Subtree(); scale=(:Leaf, :Axis), kind=:active);
        context=:plant_1)
    @test (model.registry.by_scale, model.registry.by_kind, model.registry.by_species) ==
          original_indexes
end

PlantSimEngine.@process "adaptive_output_action" verbose = false
struct AdaptiveOutputAction{F} <: AbstractAdaptive_Output_ActionModel
    action::F
end
PlantSimEngine.inputs_(::AdaptiveOutputAction) = NamedTuple()
PlantSimEngine.outputs_(::AdaptiveOutputAction) = (flux=Distributed(Default(0.0)),)
function PlantSimEngine.run!(model::AdaptiveOutputAction, status, environment, constants, context)
    model.action(context)
    return nothing
end

function adaptive_output_scene(action)
    objects = Object[Object(:scene; scale=:Scene)]
    for plant in (:plant_a, :plant_b)
        push!(objects, Object(plant; scale=:Plant, parent=:scene))
        for leaf in 1:72
            push!(objects, Object(Symbol(plant, :_leaf_, leaf);
                scale=:Leaf, kind=isodd(leaf) ? :active : :dormant, parent=plant))
        end
    end
    return CompositeModel(objects...;
        applications=(ModelSpec(AdaptiveOutputAction(action);
            name=:distributed, on=Many(scale=:Plant),
            outputs_to=(OutputTo(Many(Subtree(); scale=:Leaf, kind=:active);
                vars=(:flux,)),)),))
end

@testset "adaptive distributed destinations retain ordering and exact coverage" begin
    seen = Dict{ObjectId,Vector{ObjectId}}()
    action = context -> begin
        targets = output_targets(context, (:flux,))
        ids = collect(object_ids(targets))
        seen[object_id(context)] = ids
        # The external table may return IDs in another order. Coverage and
        # assignment must still correspond to the selected object identities.
        assign_outputs!(targets,
            (object_id=reverse(ids), flux=reverse(Float64.(eachindex(ids))));
            id=:object_id)
    end
    model = adaptive_output_scene(action)
    simulation = run!(model; outputs=:all)
    @test Set(keys(outputs(simulation))) == Set(
        (:distributed, id, :flux) for id in
        adaptive_reference_ids(model; scale=:Leaf, kind=:active))
    for plant in (:plant_a, :plant_b)
        ids = adaptive_reference_ids(model; root=plant, scale=:Leaf, kind=:active)
        @test seen[ObjectId(plant)] == ids
        @test [model_status(model, id).flux for id in ids] == Float64.(eachindex(ids))
    end
    register_object!(model, Object(:aaa_new_destination; scale=:Leaf, kind=:active,
        parent=:plant_a))
    continue!(simulation)
    @test seen[ObjectId(:plant_a)] ==
          adaptive_reference_ids(model; root=:plant_a, scale=:Leaf, kind=:active)
    @test first(seen[ObjectId(:plant_a)]) == ObjectId(:aaa_new_destination)
    @test haskey(outputs(simulation), (:distributed, ObjectId(:aaa_new_destination), :flux))

    invalid = adaptive_output_scene(context -> begin
        targets = output_targets(context, (:flux,))
        ids = collect(object_ids(targets))[1:end-1]
        assign_outputs!(targets, (object_id=ids, flux=fill(99.0, length(ids)));
            id=:object_id)
    end)
    @test_throws "missing destination ID" run!(invalid; outputs=:none)
    @test all(model_status(invalid, id).flux == 0.0
        for id in adaptive_reference_ids(invalid; scale=:Leaf, kind=:active))
end

@testset "nested scopes, relations, and cardinality" begin
    model = adaptive_selector_scene()
    for (scope, context, root) in (
        (Subtree(), :plant_1, :plant_1),
        (SelfPlant(), :leaf_1_2, :plant_1),
        (SelfPlant(), :nested_leaf, :nested_plant),
        (Ancestor(scale=:Plant), :leaf_1_2, :plant_1),
        (Scope(ObjectId(:plant_1)), nothing, :plant_1),
        (Scope(:nested_plant), nothing, :nested_plant),
    )
        @test resolve_object_ids(model, Many(scope; scale=:Leaf); context) ==
              adaptive_reference_ids(model; root, scale=:Leaf)
        @test resolve_object_ids(model, Many(; within=scope, scale=:Leaf); context) ==
              adaptive_reference_ids(model; root, scale=:Leaf)
    end
    @test resolve_object_ids(model, One(Self(); scale=:Leaf); context=:nested_leaf) ==
          ObjectId[ObjectId(:nested_leaf)]
    @test resolve_object_ids(model, One(Ancestor(scale=:Plant); scale=:Plant);
        context=:nested_leaf) == ObjectId[ObjectId(:nested_plant)]
    for relation in (:self, :parent, :children, :ancestors, :descendants, :siblings)
        for context in (:scene, :plant_1, :axis_1, :leaf_1_2, :nested_leaf)
            @test resolve_object_ids(model, Many(Relation(relation)); context) ==
                  adaptive_reference_ids(model; context, relation)
            @test resolve_object_ids(model, Many(Scope(:plant_1), Relation(relation);
                scale=(:Leaf, :Axis, :Plant)); context) ==
                  adaptive_reference_ids(model; root=:plant_1, context, relation,
                      scale=(:Leaf, :Axis, :Plant))
        end
    end
    @test resolve_object_ids(model, One(Subtree(); scale=:Leaf); context=:nested_plant) ==
          ObjectId[ObjectId(:nested_leaf)]
    @test resolve_object_ids(model, OptionalOne(Subtree(); species=:missing);
        context=:plant_1) == ObjectId[]
    @test_throws "Expected exactly one object" resolve_object_ids(model,
        One(Subtree(); scale=:Leaf); context=:plant_1)
    @test_throws "Expected zero or one object" resolve_object_ids(model,
        OptionalOne(Subtree(); scale=:Leaf); context=:plant_1)
    @test_throws "Expected exactly one object" resolve_object_ids(model,
        One(Subtree(); species=:missing); context=:large)
    @test_throws "Expected exactly one object" resolve_object_ids(model,
        One(Subtree(); scale=(:missing, :absent)); context=:large)
    @test_throws "Expected zero or one object" resolve_object_ids(model,
        OptionalOne(Subtree(); scale=(:Leaf, :Axis)); context=:plant_1)
    @test_throws "Expected zero or one object" resolve_object_ids(model,
        OptionalOne(Subtree(); species=:rare); context=:large)
    @test resolve_object_ids(model, One(Subtree(); species=:rare, id=:large_leaf_512);
        context=:large) == ObjectId[ObjectId(:large_leaf_512)]
    @test_throws "require a current object" resolve_object_ids(model,
        Many(Subtree(); scale=:Leaf))

    # Instance names take precedence over equal object IDs; explicit ObjectId
    # continues to select the object subtree instead.
    template = CompositeModelTemplate()
    scoped = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:named; scale=:Plant, parent=:scene),
        Object(:outside_leaf; scale=:Leaf, parent=:named),
        ObjectInstance(:named, template;
            root=Object(:instance_root; scale=:Plant, parent=:scene),
            objects=(Object(:inside_leaf; scale=:Leaf, parent=:instance_root),)),
    )
    @test resolve_object_ids(scoped, Many(Scope(:named); scale=:Leaf)) ==
          ObjectId[ObjectId(:inside_leaf)]
    @test resolve_object_ids(scoped, Many(Scope(ObjectId(:named)); scale=:Leaf)) ==
          ObjectId[ObjectId(:outside_leaf)]

    for scope in (Self(), Subtree(), Relation(:descendants))
        @test_throws ErrorException resolve_object_ids(model, Many(scope); context=:missing)
    end
    removable = CompositeModel(Object(:scene; scale=:Scene),
        Object(:branch; scale=:Axis, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:branch))
    selector = Many(Scope(:branch); scale=:Leaf)
    matcher = PlantSimEngine._compile_selector_matcher(removable, selector)
    remove_object!(removable, :branch)
    @test PlantSimEngine._resolve_object_ids(removable, selector, matcher) == ObjectId[]
end

@testset "deep adaptive local walk" begin
    objects = Object[Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene)]
    parent = :plant
    for index in 1:512
        id = Symbol(:deep_, index)
        push!(objects, Object(id; scale=:Axis, parent))
        parent = id
    end
    push!(objects, Object(:tip; scale=:Leaf, species=:rare, parent))
    for index in 1:1024
        push!(objects, Object(Symbol(:outside_, index); scale=:Axis, parent=:scene))
    end
    model = CompositeModel(objects...)
    @test resolve_object_ids(model, Many(Subtree(); scale=:Axis); context=:plant) ==
          adaptive_reference_ids(model; root=:plant, scale=:Axis)
    @test resolve_object_ids(model, Many(Subtree(); species=:rare); context=:plant) ==
          ObjectId[ObjectId(:tip)]
end

# Count membership comparisons without counting dictionary lookup or sorting.
# This catches quadratic ancestry scans without a wall-time or allocation bound.
struct AdaptiveAncestorId
    index::Int
end
const ADAPTIVE_ANCESTOR_ID_COMPARISONS = Ref(0)
function Base.:(==)(left::ObjectId{AdaptiveAncestorId}, right::ObjectId{AdaptiveAncestorId})
    ADAPTIVE_ANCESTOR_ID_COMPARISONS[] += 1
    return left.value.index == right.value.index
end
Base.isequal(left::ObjectId{AdaptiveAncestorId}, right::ObjectId{AdaptiveAncestorId}) =
    left.value.index == right.value.index
Base.hash(id::ObjectId{AdaptiveAncestorId}, seed::UInt) =
    hash(id.value.index, hash(AdaptiveAncestorId, seed))
Base.isless(left::AdaptiveAncestorId, right::AdaptiveAncestorId) = left.index < right.index

function adaptive_ancestor_chain(depth)
    objects = Object[Object(AdaptiveAncestorId(0); scale=:Scene)]
    for index in 1:depth
        push!(objects, Object(AdaptiveAncestorId(index);
            scale=:Axis, kind=isodd(index) ? :active : :dormant,
            species=index % 3 == 0 ? :alternate : :common,
            parent=AdaptiveAncestorId(index - 1)))
    end
    outside = AdaptiveAncestorId(depth + 1)
    push!(objects, Object(outside; scale=:Axis, kind=:active, species=:common))
    return CompositeModel(objects...), AdaptiveAncestorId(depth), outside
end

@testset "resolved ancestors avoid quadratic membership checks on deep chains" begin
    for depth in (64, 256)
        model, tip, outside = adaptive_ancestor_chain(depth)
        selector = Many(Relation(:ancestors))
        ADAPTIVE_ANCESTOR_ID_COMPARISONS[] = 0
        ids = resolve_object_ids(model, selector; context=tip)
        comparisons = ADAPTIVE_ANCESTOR_ID_COMPARISONS[]
        @test comparisons <= 4depth
        @test ids == ObjectId[ObjectId(AdaptiveAncestorId(index)) for index in 0:(depth - 1)]

        # Relation queries ignore the dependency's default scope, but still
        # intersect explicit scopes and apply all label and identity criteria.
        @test PlantSimEngine._resolve_object_ids(model, selector;
            context=tip, default_scope=Self()) == ids
        middle = depth ÷ 2
        scope = Scope(ObjectId(AdaptiveAncestorId(middle)))
        @test resolve_object_ids(model, Many(scope, Relation(:ancestors)); context=tip) ==
              ObjectId[ObjectId(AdaptiveAncestorId(index)) for index in middle:(depth - 1)]
        @test resolve_object_ids(model, Many(Scope(ObjectId(outside)), Relation(:ancestors));
            context=tip) == ObjectId[]
        @test resolve_object_ids(model, Many(scope, Relation(:ancestors);
            scale=(:Axis, :Leaf), kind=(:active, :dormant), species=:common); context=tip) ==
              ObjectId[ObjectId(AdaptiveAncestorId(index))
                       for index in middle:(depth - 1) if index % 3 != 0]
        requested = (AdaptiveAncestorId(8), AdaptiveAncestorId(middle), tip, outside)
        @test resolve_object_ids(model, Many(Relation(:ancestors); id=requested); context=tip) ==
              ObjectId[ObjectId(AdaptiveAncestorId(8)), ObjectId(AdaptiveAncestorId(middle))]
        @test resolve_object_ids(model, One(Relation(:ancestors); id=AdaptiveAncestorId(middle));
            context=tip) == ObjectId[ObjectId(AdaptiveAncestorId(middle))]
        @test resolve_object_ids(model, OptionalOne(Relation(:ancestors); id=outside);
            context=tip) == ObjectId[]
        @test resolve_object_ids(model, selector; context=AdaptiveAncestorId(0)) == ObjectId[]

        # Local descendant walks include self; borrowed ID candidates can also
        # contain self and unrelated objects. Both paths still need filtering.
        @test resolve_object_ids(model, Many(Relation(:descendants));
            context=AdaptiveAncestorId(middle)) ==
              ObjectId[ObjectId(AdaptiveAncestorId(index)) for index in (middle + 1):depth]
        @test resolve_object_ids(model, Many(Relation(:descendants);
            id=(AdaptiveAncestorId(8), AdaptiveAncestorId(middle), tip, outside));
            context=AdaptiveAncestorId(middle)) == ObjectId[ObjectId(tip)]
    end
end

PlantSimEngine.@process "adaptive_leaf_a" verbose = false
PlantSimEngine.@process "adaptive_leaf_b" verbose = false
PlantSimEngine.@process "adaptive_plant_sum" verbose = false
PlantSimEngine.@process "adaptive_optional" verbose = false

struct AdaptiveLeafA <: AbstractAdaptive_Leaf_AModel end
struct AdaptiveLeafB <: AbstractAdaptive_Leaf_BModel end
struct AdaptivePlantSum <: AbstractAdaptive_Plant_SumModel end
struct AdaptiveOptional <: AbstractAdaptive_OptionalModel end

PlantSimEngine.inputs_(::AdaptiveLeafA) = NamedTuple()
PlantSimEngine.inputs_(::AdaptiveLeafB) = NamedTuple()
PlantSimEngine.outputs_(::AdaptiveLeafA) = (a=0.0,)
PlantSimEngine.outputs_(::AdaptiveLeafB) = (b=0.0,)
PlantSimEngine.run!(::AdaptiveLeafA, status, environment, constants, context) = nothing
PlantSimEngine.run!(::AdaptiveLeafB, status, environment, constants, context) = nothing
PlantSimEngine.inputs_(::AdaptivePlantSum) = (
    values_a=Required(Vector{Float64}), values_b=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::AdaptivePlantSum) = (total_a=0.0, total_b=0.0, seen_ids=ObjectId[])
function PlantSimEngine.run!(::AdaptivePlantSum, status, environment, constants, context)
    values_a = bound_input(context, :values_a)
    values_b = bound_input(context, :values_b)
    @assert object_ids(values_a) == object_ids(values_b)
    status.seen_ids = collect(object_ids(values_a))
    status.total_a = sum(values_a; init=0.0)
    status.total_b = sum(values_b; init=0.0)
    return nothing
end
PlantSimEngine.inputs_(::AdaptiveOptional) = (optional=Default(7.0),)
PlantSimEngine.outputs_(::AdaptiveOptional) = (observed=0.0,)
function PlantSimEngine.run!(::AdaptiveOptional, status, environment, constants, context)
    status.observed = status.optional
    return nothing
end

function adaptive_binding_scene()
    objects = Object[Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene)]
    for plant in (:plant_a, :plant_b), leaf in 1:72
        push!(objects, Object(Symbol(plant, :_leaf_, leaf);
            scale=:Leaf, kind=:active, parent=plant,
            status=Status(a=Float64(leaf), b=Float64(10leaf))))
    end
    return CompositeModel(objects...;
        applications=(
            ModelSpec(AdaptiveLeafA(); name=:leaf_a, on=Many(scale=:Leaf)),
            ModelSpec(AdaptiveLeafB(); name=:leaf_b, on=Many(scale=:Leaf)),
            ModelSpec(AdaptivePlantSum(); name=:plant_sum, on=Many(scale=:Plant),
                inputs=(
                    values_a=Many(Subtree(); scale=:Leaf, kind=:active, application=:leaf_a, var=:a),
                    values_b=Many(Subtree(); scale=:Leaf, kind=:active, application=:leaf_b, var=:b),
                )),
            ModelSpec(AdaptiveOptional(); name=:optional, on=Many(scale=:Plant),
                inputs=(optional=OptionalOne(Subtree(); species=:missing,
                    var=:a, from_status=true),)),
        ),
    )
end

function adaptive_binding(compiled, plant, input)
    return only(binding for binding in compiled.input_bindings_by_target[
        (:plant_sum, ObjectId(plant))] if binding.input == input)
end

function adaptive_check_bindings(model, compiled; check_runtime=false)
    for plant in (:plant_a, :plant_b)
        ids = adaptive_reference_ids(model; root=plant, scale=:Leaf, kind=:active)
        for (input, variable, producer) in ((:values_a, :a, :leaf_a), (:values_b, :b, :leaf_b))
            binding = adaptive_binding(compiled, plant, input)
            @test binding.source_ids == ids
            @test binding.source_application_ids == [producer]
            carrier = input_carrier(binding)
            @test carrier isa PlantSimEngine.RefVector
            @test collect(carrier) == [getproperty(model_status(model, id), variable) for id in ids]
            @test all(reference === PlantSimEngine.refvalue(model_status(model, id), variable)
                for (id, reference) in zip(ids, parent(carrier)))
        end
        if check_runtime
            status = model_status(model, plant)
            @test status.seen_ids == ids
            @test status.total_a == sum((model_status(model, id).a for id in ids); init=0.0)
            @test status.total_b == sum((model_status(model, id).b for id in ids); init=0.0)
        end
    end
end

@testset "adaptive bindings preserve producers, references, and lifecycle membership" begin
    model = adaptive_binding_scene()
    simulation = run!(model; outputs=:none)
    original = simulation.compiled
    adaptive_check_bindings(model, original; check_runtime=true)
    @test all(model_status(model, plant).observed == 7.0 for plant in (:plant_a, :plant_b))
    @test all(model_status(model, plant).seen_ids ==
        adaptive_reference_ids(model; root=plant, scale=:Leaf, kind=:active)
        for plant in (:plant_a, :plant_b))

    bindings = [adaptive_binding(original, plant, input)
        for plant in (:plant_a, :plant_b) for input in (:values_a, :values_b)]
    carriers = input_carrier.(bindings)
    model_status(model, :plant_a_leaf_1).a = 123.0
    model_status(model, :plant_a_leaf_1).b = 456.0
    @test Advanced.refresh_bindings!(model) === original
    continue!(simulation)
    @test simulation.compiled === original
    @test all(adaptive_binding(simulation.compiled, plant, input) === binding
        for ((plant, input), binding) in zip(
            [(plant, input) for plant in (:plant_a, :plant_b) for input in (:values_a, :values_b)], bindings))
    @test all(input_carrier(binding) === carrier for (binding, carrier) in zip(bindings, carriers))
    adaptive_check_bindings(model, simulation.compiled; check_runtime=true)

    # New IDs sort before old ones; refresh must preserve deterministic order
    # even when the monotonic append shortcut cannot apply.
    register_object!(model, Object(:aaa_new_leaf; scale=:Leaf, kind=:active,
        parent=:plant_a, status=Status(a=2.0, b=20.0)))
    continue!(simulation)
    adaptive_check_bindings(model, simulation.compiled; check_runtime=true)
    @test first(adaptive_binding(simulation.compiled, :plant_a, :values_a).source_ids) ==
          ObjectId(:aaa_new_leaf)

    reparent_object!(model, :plant_a_leaf_2, :plant_b)
    continue!(simulation)
    adaptive_check_bindings(model, simulation.compiled; check_runtime=true)
    @test ObjectId(:plant_a_leaf_2) ∉ adaptive_binding(simulation.compiled, :plant_a, :values_a).source_ids
    @test ObjectId(:plant_a_leaf_2) ∈ adaptive_binding(simulation.compiled, :plant_b, :values_a).source_ids

    remove_object!(model, :aaa_new_leaf)
    continue!(simulation)
    adaptive_check_bindings(model, simulation.compiled; check_runtime=true)
    @test ObjectId(:aaa_new_leaf) ∉ adaptive_binding(simulation.compiled, :plant_a, :values_a).source_ids

    # The graph editor's metadata edit returns an independently owned model,
    # reindexes labels and requests a full binding refresh for the edited scene.
    relabeled = apply_model_graph_edit(model,
        SetModelObjectMetadata(:plant_a_leaf_3; kind=:dormant))
    relabeled_compiled = Advanced.refresh_bindings!(relabeled)
    adaptive_check_bindings(relabeled, relabeled_compiled)
    @test ObjectId(:plant_a_leaf_3) ∉ adaptive_binding(relabeled_compiled, :plant_a, :values_a).source_ids
    @test ObjectId(:plant_a_leaf_3) ∈ adaptive_binding(simulation.compiled, :plant_a, :values_a).source_ids

    # A separately owned scene with equal object IDs must never reuse results
    # from the previous scene's different topology or labels.
    independent = adaptive_binding_scene()
    independent_compiled = Advanced.refresh_bindings!(independent)
    adaptive_check_bindings(independent, independent_compiled)
    @test ObjectId(:plant_a_leaf_3) ∈ adaptive_binding(independent_compiled, :plant_a, :values_a).source_ids
    @test ObjectId(:plant_a_leaf_2) ∈ adaptive_binding(independent_compiled, :plant_a, :values_a).source_ids
end

PlantSimEngine.@process "adaptive_partition_sum" verbose = false
struct AdaptivePartitionSum <: AbstractAdaptive_Partition_SumModel end
PlantSimEngine.inputs_(::AdaptivePartitionSum) = (
    active_values=Required(Vector{Float64}),
    dormant_values=Required(Vector{Float64}),
    supplied_values=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::AdaptivePartitionSum) = (
    total_active=0.0, total_dormant=0.0, total_supplied=0.0,
)
function PlantSimEngine.run!(::AdaptivePartitionSum, status, environment, constants, context)
    status.total_active = sum(bound_input(context, :active_values); init=0.0)
    status.total_dormant = sum(bound_input(context, :dormant_values); init=0.0)
    status.total_supplied = sum(bound_input(context, :supplied_values); init=0.0)
    return nothing
end

function adaptive_partition_scene(reverse_inputs)
    objects = Object[Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene)]
    for index in 1:72
        push!(objects, Object(Symbol(:leaf_, index); scale=:Leaf,
            kind=isodd(index) ? :active : :dormant, parent=:plant,
            status=Status(a=Float64(index), b=Float64(10index), supplied=1.0)))
    end
    inputs = (
        active_values=Many(Subtree(); scale=:Leaf, application=:active, var=:a),
        dormant_values=Many(Subtree(); scale=:Leaf, application=:dormant, var=:b),
        supplied_values=Many(Subtree(); scale=:Leaf, var=:supplied, from_status=true),
    )
    reverse_inputs && (inputs = (
        supplied_values=inputs.supplied_values,
        dormant_values=inputs.dormant_values,
        active_values=inputs.active_values,
    ))
    return CompositeModel(objects...; applications=(
        ModelSpec(AdaptiveLeafB(); name=:dormant, on=Many(scale=:Leaf, kind=:dormant)),
        ModelSpec(AdaptiveLeafA(); name=:active, on=Many(scale=:Leaf, kind=:active)),
        ModelSpec(AdaptivePartitionSum(); name=:partition, on=One(id=:plant), inputs),
    ))
end

@testset "shared object queries keep input-specific producer filtering and ownership" begin
    for reverse_inputs in (false, true)
        model = adaptive_partition_scene(reverse_inputs)
        simulation = run!(model; outputs=:none)
        bindings = Dict(binding.input => binding for binding in
            simulation.compiled.input_bindings_by_target[(:partition, ObjectId(:plant))])
        for (input, kind, variable, producer, output) in (
            (:active_values, :active, :a, :active, :total_active),
            (:dormant_values, :dormant, :b, :dormant, :total_dormant),
            (:supplied_values, nothing, :supplied, nothing, :total_supplied),
        )
            ids = adaptive_reference_ids(model; root=:plant, scale=:Leaf, kind)
            binding = bindings[input]
            @test binding.source_ids == ids
            @test binding.source_application_ids == (isnothing(producer) ? Symbol[] : [producer])
            @test all(reference === PlantSimEngine.refvalue(model_status(model, id), variable)
                for (id, reference) in zip(ids, parent(input_carrier(binding))))
            @test getproperty(model_status(model, :plant), output) ==
                  sum((getproperty(model_status(model, id), variable) for id in ids); init=0.0)
        end

        # The cache is deliberately scoped to one consumer assembly. A cached
        # unfiltered result must remain owned separately from every returned
        # vector, because writer filtering mutates those returned vectors.
        cache = Dict{Any,Vector{ObjectId}}()
        selectors = (bindings[:active_values].selector, bindings[:dormant_values].selector,
            bindings[:supplied_values].selector)
        expected = adaptive_reference_ids(model; root=:plant, scale=:Leaf)
        first_ids = PlantSimEngine._cached_dependency_object_ids(cache, model,
            selectors[1], PlantSimEngine._compile_selector_matcher(model, selectors[1]), ObjectId(:plant))
        @test first_ids == expected
        empty!(first_ids)
        second_ids = PlantSimEngine._cached_dependency_object_ids(cache, model,
            selectors[2], PlantSimEngine._compile_selector_matcher(model, selectors[2]), ObjectId(:plant))
        @test second_ids == expected
        pop!(second_ids)
        third_ids = PlantSimEngine._cached_dependency_object_ids(cache, model,
            selectors[3], PlantSimEngine._compile_selector_matcher(model, selectors[3]), ObjectId(:plant))
        @test third_ids == expected
        @test length(cache) == 1
        @test only(values(cache)) == expected
        @test only(values(cache)) !== third_ids
    end
end
