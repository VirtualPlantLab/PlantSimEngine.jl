module MTGBirthStatusTypeChecks

using PlantSimEngine, Test
import MultiScaleTreeGraph as MTG
const PSE = PlantSimEngine

struct InitialStatus{T}
    original::Base.RefValue{T}
    declarations::Base.RefValue{Int}
end
InitialStatus(value) = InitialStatus(Ref(value), Ref(0))

function (init::InitialStatus)(node)
    MTG.symbol(node) === :Scene && return Status(organ_symbol=:Blade)
    if MTG.symbol(node) === :Blade
        MTG.symbol(MTG.parent(node)) === :Numeric && return Status(mass=1.5)
        return Status((mass=init.original,))
    end
    return nothing
end

function PSE.birth_status_types(init::InitialStatus, objects)
    init.declarations[] += 1
    plant = only(object for object in objects if object.scale === :Scene)
    return Dict(plant.status.organ_symbol => (mass=Union{Float64,String},))
end

@process "birth_status_reader" verbose=false
struct NumericReader{T} <: AbstractBirth_Status_ReaderModel end
NumericReader() = NumericReader{Real}()
struct MixedReader <: AbstractBirth_Status_ReaderModel end
PSE.inputs_(::NumericReader{T}) where {T} = (values=Required(Vector{T}),)
PSE.inputs_(::MixedReader) = (values=Default(Float32[]),)
PSE.outputs_(::Union{NumericReader,MixedReader}) = (total=0.0,)
function PSE.run!(::NumericReader, status, environment, constants, context)
    status.total = sum(bound_input(context, :values); init=0.0)
end
function PSE.run!(::MixedReader, status, environment, constants, context)
    status.total = sum((v for v in bound_input(context, :values) if v isa Real); init=0.0)
end

root() = MTG.Node(1, MTG.NodeMTG(:/, :Scene, 1, 0), NamedTuple())
child(id, parent, scale) = MTG.Node(id, parent, MTG.NodeMTG(:+, scale, 1, 1), NamedTuple())
reader(m, name, target, scope) = ModelSpec(m; name, on=target,
    inputs=(values=Many(within=scope, scale=:Blade, var=:mass, from_status=true),))
plant_leaf(model, parent, cell) = add_organ!(parent, model, :+, :Blade, 1;
    initial_status=Status((mass=cell,)))

@testset "Declared future fields follow the selected reader" begin
    tree = root()
    numeric = child(2, tree, :Numeric)
    mixed = child(3, tree, :Mixed)
    child(4, tree, :Blade)
    child(5, numeric, :Blade)
    init = InitialStatus("outside")
    model = CompositeModel(tree; status=init, applications=(
        reader(NumericReader(), :numeric, One(id=2), Subtree()),
        reader(MixedReader(), :mixed, One(id=3), Subtree()),
    ))
    sim = run!(model; steps=1, outputs=:all)
    @test PSE.refvalue(model_status(model, 4), :mass) === init.original
    @test model_status(model, 2).total === 1.5
    previous_outputs = Dict(k => copy(v) for (k, v) in outputs(sim))
    previous_ids = object_ids(model)
    @test_throws ArgumentError plant_leaf(model, numeric, Ref("invalid"))
    @test object_ids(model) == previous_ids
    @test MTG.node_id.(MTG.children(numeric)) == [5] && isnothing(MTG.get_node(tree, 6))
    @test outputs(sim) == previous_outputs && current_step(sim) == 1

    mass = Ref(2.5)
    leaf = plant_leaf(model, numeric, mass)
    @test MTG.node_id(source_node(model, leaf)) == 6
    @test PSE.refvalue(leaf, :mass) === mass
    label = Ref("allowed")
    @test PSE.refvalue(plant_leaf(model, mixed, label), :mass) === label
    soft_mass = Ref(4.0)
    @test PSE.refvalue(plant_leaf(model, mixed, soft_mass), :mass) === soft_mass
    step!(sim)
    @test model_status(model, 2).total === 4.0
    @test model_status(model, 3).total === 4.0
    @test PSE.refvalue(model_status(model, 4), :mass) === init.original
    @test init.declarations[] == 1
end

@testset "A future reader checks independently owned data when it binds" begin
    for (value, valid) in (("outside", false), (3.5, true))
        tree = root()
        child(2, tree, :Blade)
        init = InitialStatus(value)
        model = CompositeModel(tree; status=init, applications=(
            reader(NumericReader(), :reader, Many(scale=:Numeric), SceneScope()),))
        sim = run!(model; steps=0, outputs=:all)
        @test PSE.refvalue(model_status(model, 2), :mass) === init.original
        add_organ!(tree, model, :+, :Numeric, 1)
        if valid
            step!(sim)
            @test model_status(model, 3).total === value
        else
            before = Dict(k => copy(v) for (k, v) in outputs(sim))
            @test_throws ArgumentError continue!(sim; steps=0)
            @test current_step(sim) == 0 && outputs(sim) == before
        end
        @test PSE.refvalue(model_status(model, 2), :mass) === init.original
        @test init.declarations[] == 1
    end
end

struct OtherFields{D}
    fields::D
    mass::Base.RefValue{String}
end
PSE.birth_status_types(init::OtherFields, objects) = init.fields
(init::OtherFields)(node) = MTG.symbol(node) === :Blade ? Status((mass=init.mass,)) : nothing

@testset "Future fields follow the configured storage type" begin
    tree = root()
    declared = OtherFields((Blade=(mass=Float64,),), Ref("unused"))
    model = CompositeModel(tree; status=declared, type_promotion=Dict(Float64 => Float32))
    leaf = add_organ!(tree, model, :+, :Blade, 1; initial_status=(mass=2.5,))
    @test leaf.mass === 2.5f0
    @test PSE.refvalue(leaf, :mass) === PSE.refvalue(model_status(model, 2), :mass)

    for fields in (Dict("Blade" => (mass=Float64,)), (Blade=(mass=1.0,),), (Blade=(mass=Real,),))
        @test_throws ArgumentError CompositeModel(root(); status=OtherFields(fields, Ref("unused")))
    end
end

@testset "Other fields and other scales preserve the original RAW cell" begin
    for fields in (nothing, (Blade=(other=Int,),),
        (Blade=(other=Int,), Flower=(mass=Float64,)))
        init = OtherFields(fields, Ref("outside"))
        tree = root()
        child(2, tree, :Blade)
        spec = ModelSpec(NumericReader(); name=:reader, on=Many(scale=:Numeric), inputs=(
            values=Many(within=SceneScope(), scale=(:Blade, :Flower), var=:mass, from_status=true),))
        model = CompositeModel(tree; status=init, applications=(spec,))
        sim = run!(model; steps=0, outputs=:all)
        @test PSE.refvalue(model_status(model, 2), :mass) === init.mass
        new_cell = Ref("another blade")
        @test PSE.refvalue(plant_leaf(model, tree, new_cell), :mass) === new_cell
        before = Dict(k => copy(v) for (k, v) in outputs(sim))
        add_organ!(tree, model, :+, :Numeric, 1)
        @test_throws ArgumentError continue!(sim; steps=0)
        @test current_step(sim) == 0 && outputs(sim) == before
        @test PSE.refvalue(model_status(model, 2), :mass) === init.mass
    end
end

struct ScalarReader{T} <: AbstractBirth_Status_ReaderModel end
ScalarReader() = ScalarReader{Real}()
PSE.inputs_(::ScalarReader{T}) where {T} = (value=Required(T),)
PSE.outputs_(::ScalarReader) = (total=0.0,)
PSE.run!(::ScalarReader, status, environment, constants, context) = (status.total = status.value)

@testset "One and OptionalOne keep the declared scalar input type" begin
    for selector in (One, OptionalOne)
        function build(value)
            tree = root()
            child(2, tree, :Blade)
            init = InitialStatus(value)
            model = CompositeModel(tree; status=init, applications=(ModelSpec(ScalarReader();
                name=:reader, on=One(id=1), inputs=(value=selector(
                    within=SceneScope(), id=2, var=:mass, from_status=true),)),))
            return model, init
        end
        model, init = build(3.0)
        run!(model; steps=1)
        @test model_status(model, 1).total === 3.0
        @test PSE.refvalue(model_status(model, 1), :value) === init.original
        @test_throws ArgumentError run!(first(build("invalid")); steps=0)
    end
    @test PSE.birth_status_types(identity, ()) === nothing
end

@testset "A future reader can own a compatible cell before its first target exists" begin
    for (reader, input, selector) in ((ScalarReader{Float64}(), :value, One),
        (NumericReader{Float64}(), :values, Many))
        root = MTG.Node(1, MTG.NodeMTG(:/, :Scene, 1, 0), NamedTuple())
        source = selector(within=SceneScope(), scale=:Blade, var=:x, from_status=true)
        spec = ModelSpec(reader; name=:reader, on=Many(scale=:Collector), inputs=(; input => source))
        model = CompositeModel(root; applications=(spec,))
        sim = run!(model; steps=0, outputs=:all)
        real = Ref(2.0)
        leaf = add_organ!(root, model, :+, :Blade, 1; initial_status=Status((x=real,)))
        @test PSE.refvalue(leaf, :x) === real
        add_organ!(root, model, :+, :Collector, 1)
        step!(sim)
        @test model_status(model, 3).total === 2.0
        @test PSE.refvalue(model_status(model, 2), :x) === real
    end
end

end
