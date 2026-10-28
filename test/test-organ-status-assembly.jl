# The oracle deliberately retains the former Dict assembly sequence. Do not
# implement it with _status_data! or the production organ-status assembler:
# they are the code under test, including their ordering and alias behavior.
function _organ_assembly_reference_overlay!(destination, source)
    source === nothing && return destination
    source isa Union{Status,NamedTuple,AbstractDict,Base.Pairs} ||
        error("unsupported organ-status source")
    entries = source isa Status ? NamedTuple(source) : source
    for (raw_key, value) in pairs(entries)
        key = Symbol(raw_key)
        if key === :plantsimengine_status
            value === nothing && continue
            error("reserved runtime-status value")
        end
        destination[key] = value
    end
    return destination
end

function _organ_assembly_reference(node, adapted_status, initial_status)
    data = Dict{Symbol,Any}()
    _organ_assembly_reference_overlay!(data, MultiScaleTreeGraph.node_attributes(node))
    _organ_assembly_reference_overlay!(data, adapted_status)
    data[:node] = node
    _organ_assembly_reference_overlay!(data, initial_status)
    data[:node] = node
    names = Tuple(keys(data))
    # Wrap every scientific value exactly once, even when that value is itself
    # a Ref. The all-Ref NamedTuple dispatch then preserves these fresh carriers.
    return Status(NamedTuple{names}(Ref.(Tuple(values(data)))))
end

function _organ_assembly_source(kind, values)
    kind === :nothing && return nothing
    kind === :namedtuple && return values
    kind === :symbol_dict && return Dict{Symbol,Any}(pairs(values))
    kind === :string_dict && return Dict{String,Any}(
        String(key) => value for (key, value) in pairs(values)
    )
    kind === :pairs && return pairs(values)
    kind === :status && return Status(; values...)
    error("unsupported test source kind")
end

function _organ_assembly_fixture(adapted_status; attributes=NamedTuple())
    root = MultiScaleTreeGraph.Node(
        MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0),
    )
    model = CompositeModel(
        root;
        status=node -> node === root ? nothing : adapted_status,
    )
    node = MultiScaleTreeGraph.Node(
        root,
        MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 1),
        attributes,
    )
    return model, node
end

function _organ_assembly_assert_reference(actual, expected)
    @test propertynames(actual) == propertynames(expected)
    @test Tuple(actual) == Tuple(expected)
    @test typeof(actual) === typeof(expected)
    for name in propertynames(expected)
        @test actual[name] === expected[name]
        @test PlantSimEngine.refvalue(actual, name) !==
              PlantSimEngine.refvalue(expected, name)
    end
end

@testset "organ status assembly independent overlay oracle" begin
    source_kinds = (:nothing, :namedtuple, :symbol_dict, :string_dict, :pairs, :status)
    for adapted_kind in source_kinds, initial_kind in source_kinds
        payload = [1, 2]
        nested_reference = Ref(7)
        adapted = _organ_assembly_source(adapted_kind, (
            overlap=2,
            adapter_only=22,
            node=:adapter_node,
            payload=payload,
            nested_reference=nested_reference,
            plantsimengine_status=nothing,
        ))
        initial = _organ_assembly_source(initial_kind, (
            overlap=3,
            initial_only=33,
            node=:initial_node,
            plantsimengine_status=nothing,
        ))
        model, node = _organ_assembly_fixture(adapted; attributes=(
            overlap=1,
            attribute_only=11,
            node=:attribute_node,
        ))
        actual = PlantSimEngine._organ_status(model.source_adapter, node, initial)
        expected = _organ_assembly_reference(node, adapted, initial)
        _organ_assembly_assert_reference(actual, expected)
        @test actual.node === node
        @test !hasproperty(actual, :plantsimengine_status)
        @test node[:node] === :attribute_node
        @test actual.overlap == (initial_kind !== :nothing ? 3 : adapted_kind !== :nothing ? 2 : 1)
        if adapted_kind !== :nothing
            @test actual.payload === payload
            @test actual.nested_reference === nested_reference
        end
    end
end

@testset "organ status assembly retains former Dict field order across widths" begin
    # Include sizes on both sides of table growth boundaries, with :node first
    # introduced either by attributes or between the two overlay stages.
    for attribute_count in (0, 7, 15, 31, 63), initial_count in (0, 1, 7, 17), attribute_node in (false, true)
        attributes = Dict{Symbol,Any}(
            Symbol("attribute_", i) => i for i in 1:attribute_count
        )
        attribute_node && (attributes[:node] = :attribute_node)
        initial = Dict{Symbol,Any}(
            Symbol("initial_", i) => i for i in 1:initial_count
        )
        initial[:node] = :initial_node
        model, node = _organ_assembly_fixture(nothing; attributes=attributes)
        actual = PlantSimEngine._organ_status(model.source_adapter, node, initial)
        expected = _organ_assembly_reference(node, nothing, initial)
        _organ_assembly_assert_reference(actual, expected)
    end
end

@testset "organ status assembly observes adapter effects before attributes" begin
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    calls = Ref(0)
    model = CompositeModel(root; status=node -> begin
        node === root && return nothing
        calls[] += 1
        node[:created_by_adapter] = calls[]
        node[:overlap] = 9
        return (overlap=10,)
    end)
    node = MultiScaleTreeGraph.Node(
        root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 1), (overlap=1,),
    )
    bypassed = PlantSimEngine._organ_status(
        model.source_adapter, node, nothing; use_status_adapter=false,
    )
    @test calls[] == 0
    @test bypassed.overlap == 1
    @test !hasproperty(bypassed, :created_by_adapter)
    adapted = PlantSimEngine._organ_status(model.source_adapter, node, (overlap=11,))
    @test calls[] == 1
    @test adapted.created_by_adapter == 1
    @test adapted.overlap == 11
    @test node[:overlap] == 9
end

@testset "organ status assembly copies carriers and shares scientific payloads" begin
    payload = [1, 2]
    nested_reference = Ref(7)
    source = Status(payload=payload, nested_reference=nested_reference, scalar=1)
    model, node = _organ_assembly_fixture(source)
    first = PlantSimEngine._organ_status(model.source_adapter, node, nothing)
    second = PlantSimEngine._organ_status(model.source_adapter, node, nothing)
    for name in (:payload, :nested_reference, :scalar)
        @test PlantSimEngine.refvalue(first, name) !== PlantSimEngine.refvalue(source, name)
        @test PlantSimEngine.refvalue(first, name) !== PlantSimEngine.refvalue(second, name)
    end
    @test first.payload === payload === second.payload
    @test first.nested_reference === nested_reference === second.nested_reference
    push!(payload, 3)
    nested_reference[] = 8
    @test first.payload == [1, 2, 3]
    @test first.nested_reference[] == 8
    source.scalar = 99
    source.payload = [4]
    source.nested_reference = Ref(9)
    @test first.scalar == second.scalar == 1
    @test first.payload === payload
    @test first.nested_reference === nested_reference
    first.scalar = 2
    @test second.scalar == 1
end

@testset "organ status assembly rejects real reserved values in either overlay" begin
    kinds = (:namedtuple, :symbol_dict, :string_dict, :pairs, :status)
    for kind in kinds, reserved in (false, Ref(nothing), Status(signal=1))
        invalid = _organ_assembly_source(kind, (plantsimengine_status=reserved,))
        model, node = _organ_assembly_fixture(invalid)
        @test_throws ErrorException PlantSimEngine._organ_status(
            model.source_adapter, node, nothing,
        )
        @test_throws ErrorException PlantSimEngine._organ_status(
            model.source_adapter, node, invalid; use_status_adapter=false,
        )
    end
end

@testset "organ status assembly failures remove newborn identities and recover" begin
    for failure in (:adapter_throw, :invalid_adapter, :invalid_initial, :reserved_adapter, :reserved_initial, :reserved_attribute)
        root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
        newborn = Ref{Any}(nothing)
        model = CompositeModel(root; status=node -> begin
            node === root && return nothing
            newborn[] = node
            failure === :adapter_throw && error("intentional assembly failure")
            failure === :invalid_adapter && return 17
            failure === :reserved_adapter && return (plantsimengine_status=Status(signal=1),)
            failure === :reserved_attribute && (node[:plantsimengine_status] = Status(signal=1))
            return nothing
        end)
        initial = failure === :invalid_initial ? 17 :
                  failure === :reserved_initial ? (plantsimengine_status=Status(signal=1),) : nothing
        initial_ids = object_ids(model)
        initial_forward = copy(model.source_adapter.object_ids_by_node)
        initial_reverse = copy(model.source_adapter.nodes_by_object_id)
        initial_added = length(model.lifecycle_delta.added)
        @test_throws ErrorException add_organ!(
            root, model, :+, :Leaf, 1; initial_status=initial,
        )
        @test isempty(MultiScaleTreeGraph.children(root))
        @test object_ids(model) == initial_ids
        @test model.source_adapter.object_ids_by_node == initial_forward
        @test model.source_adapter.nodes_by_object_id == initial_reverse
        @test length(model.lifecycle_delta.added) == initial_added
        @test_throws ArgumentError object_id(model, newborn[])
        # ColumnarAttrs may retain an empty reserved column after failed adapter
        # mutation; that placeholder must not poison the next valid insertion.
        recovered = add_organ!(
            root, model, :+, :Leaf, 1;
            initial_status=(signal=3,), use_status_adapter=false,
        )
        @test recovered.signal == 3
        @test recovered.node === only(MultiScaleTreeGraph.children(root))
        @test model_status(model, recovered.node) === recovered
        @test !hasproperty(recovered, :plantsimengine_status)
    end
end

@testset "Status value constructors preserve nested Ref distinction" begin
    reference = Ref(7)
    carrier_status = Status((value=reference,))
    tuple_status = Status{(:value,)}((reference,))
    keyword_status = Status(value=reference)
    @test carrier_status.value == 7
    @test PlantSimEngine.refvalue(carrier_status, :value) === reference
    @test tuple_status.value === reference
    @test keyword_status.value === reference
    @test PlantSimEngine.refvalue(tuple_status, :value) !== reference
    @test PlantSimEngine.refvalue(keyword_status, :value) !== reference
end

function _organ_assembly_assert_live(model, node; initial_status=NamedTuple(), use_status_adapter=true)
    actual = PlantSimEngine._organ_status(
        model.source_adapter, node, initial_status;
        use_status_adapter=use_status_adapter,
    )
    expected = _organ_assembly_reference(node, nothing, initial_status)
    _organ_assembly_assert_reference(actual, expected)
    @test actual.node === node
    return actual
end

@testset "organ status repeated layouts read each newborn's live values" begin
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    model = CompositeModel(root)
    first_payload, second_payload = [1], [2]
    first = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(value=1, payload=first_payload, nullable=nothing),
    )
    second = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(value=2, payload=second_payload, nullable=nothing),
        initial_status=nothing,
    )
    _organ_assembly_assert_reference(first, _organ_assembly_reference(first.node, nothing, NamedTuple()))
    _organ_assembly_assert_reference(second, _organ_assembly_reference(second.node, nothing, nothing))
    @test first.value == 1
    @test second.value == 2
    @test first.payload === first_payload
    @test second.payload === second_payload
    @test first.node !== second.node
    @test PlantSimEngine.refvalue(first, :value) !== PlantSimEngine.refvalue(second, :value)
    second.node[:value] = 3
    reread = _organ_assembly_assert_live(model, second.node; initial_status=nothing)
    @test reread.value == 3
    @test first.value == 1
    @test second.value == 2
end

@testset "organ status layouts follow column schema and row-local presence" begin
    model, node = _organ_assembly_fixture(nothing; attributes=(kept=1, nullable=nothing, local_value=3))
    root = MultiScaleTreeGraph.get_root(node)
    _organ_assembly_assert_live(model, node)
    delete!(node, :local_value)
    absent = _organ_assembly_assert_live(model, node)
    @test !hasproperty(absent, :local_value)
    @test hasproperty(absent, :nullable)
    @test absent.nullable === nothing
    node[:added_column] = 4
    @test _organ_assembly_assert_live(model, node).added_column == 4
    sibling = MultiScaleTreeGraph.Node(
        root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 1), (kept=2, local_value=9),
    )
    sibling_status = _organ_assembly_assert_live(model, sibling; initial_status=nothing)
    @test sibling_status.local_value == 9
    @test !hasproperty(sibling_status, :nullable)
    @test !hasproperty(sibling_status, :added_column)
    node[:local_value] = 5
    @test _organ_assembly_assert_live(model, node).local_value == 5
    MultiScaleTreeGraph.drop_column!(root, :Leaf, :added_column)
    @test !hasproperty(_organ_assembly_assert_live(model, node), :added_column)
    MultiScaleTreeGraph.rename_column!(root, :Leaf, :kept, :renamed)
    renamed = _organ_assembly_assert_live(model, node)
    @test renamed.renamed == 1
    @test !hasproperty(renamed, :kept)
    MultiScaleTreeGraph.drop_column!(root, :Leaf, :local_value)
    @test !hasproperty(_organ_assembly_assert_live(model, sibling), :local_value)
end

@testset "organ status layouts include defaults while respecting explicit absence" begin
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    model = CompositeModel(root)
    MultiScaleTreeGraph.add_column!(root, :Leaf, :temperature, Float64; default=20.0)
    first = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 1), (value=1,))
    second = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 1), (value=2, temperature=25.0))
    @test _organ_assembly_assert_live(model, first).temperature == 20.0
    @test _organ_assembly_assert_live(model, second).temperature == 25.0
    pop!(first, :temperature)
    @test !hasproperty(_organ_assembly_assert_live(model, first), :temperature)
    third = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 3, 1), (value=3,))
    @test _organ_assembly_assert_live(model, third; initial_status=nothing).temperature == 20.0
    MultiScaleTreeGraph.add_column!(root, :Leaf, :humidity, Float64; default=0.5)
    @test _organ_assembly_assert_live(model, first).humidity == 0.5
    @test _organ_assembly_assert_live(model, second).humidity == 0.5
end

@testset "organ status layouts survive row relocation and column widening" begin
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    model = CompositeModel(root)
    first_payload, last_payload = [1], [2]
    first = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 1), (value=1, payload=first_payload))
    last = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 1), (value=2, payload=last_payload))
    _organ_assembly_assert_live(model, first)
    _organ_assembly_assert_live(model, last)
    # Deleting the first row relocates the last row in the columnar bucket.
    MultiScaleTreeGraph.delete_node!(first)
    relocated = _organ_assembly_assert_live(model, last)
    @test relocated.value == 2
    @test relocated.payload === last_payload
    wide_payload = [3]
    widened = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 3, 1), (value="wide", payload=wide_payload))
    @test _organ_assembly_assert_live(model, widened).value == "wide"
    @test _organ_assembly_assert_live(model, last).value === 2
    last[:value] = 3 // 2
    reread = _organ_assembly_assert_live(model, last; initial_status=nothing)
    @test reread.value === 3 // 2
    @test reread.payload === last_payload
end

@testset "organ status layouts observe callbacks returning nothing on every call" begin
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    calls = Ref(0)
    model = CompositeModel(root; status=node -> begin
        node === root && return nothing
        calls[] += 1
        node[:callback_value] = calls[]
        node[:signal] += 1
        if isodd(calls[])
            node[:odd_only] = calls[]
        else
            delete!(node, :odd_only)
        end
        return nothing
    end)
    node = MultiScaleTreeGraph.Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 1), (signal=1,))
    for call in 1:3
        status = _organ_assembly_assert_live(model, node)
        @test calls[] == call
        @test status.callback_value == call
        @test status.signal == call + 1
        @test hasproperty(status, :odd_only) == isodd(call)
    end
    bypassed = _organ_assembly_assert_live(model, node; use_status_adapter=false)
    @test calls[] == 3
    @test bypassed.callback_value == 3
end

@testset "organ status equal layouts remain independent between model instances" begin
    first_payload, second_payload = [1], [2]
    first_reference, second_reference = Ref(1), Ref(2)
    first_model, first_node = _organ_assembly_fixture(nothing;
        attributes=(value=1, payload=first_payload, scientific_ref=first_reference),
    )
    second_model, second_node = _organ_assembly_fixture(nothing;
        attributes=(value=2, payload=second_payload, scientific_ref=second_reference),
    )
    first = _organ_assembly_assert_live(first_model, first_node)
    second = _organ_assembly_assert_live(second_model, second_node)
    repeated_first = _organ_assembly_assert_live(first_model, first_node; initial_status=nothing)
    @test first.payload === repeated_first.payload === first_payload
    @test second.payload === second_payload
    @test first.scientific_ref === first_reference
    @test second.scientific_ref === second_reference
    @test first.node === repeated_first.node === first_node
    @test second.node === second_node
    @test PlantSimEngine.refvalue(first, :value) !== PlantSimEngine.refvalue(repeated_first, :value)
    first_node[:value] = 3
    @test _organ_assembly_assert_live(first_model, first_node).value == 3
    @test _organ_assembly_assert_live(second_model, second_node).value == 2
end

@testset "organ helper and Status constructors preserve historical wrapping across widths" begin
    for width in (0, 1, 8, 36, 64, 129)
        names = ntuple(i -> Symbol("constructor_value_", i), width)
        data = ntuple(i -> isodd(i) ? Float32(i) : BigFloat(i), width)
        named = NamedTuple{names}(data)
        historical = Status(NamedTuple{names}(Ref.(data)))
        constructed = (
            Status{names}(data), Status(named), Status(; named...),
            PlantSimEngine._organ_status_from_values(Val(names), data),
        )
        for status in constructed
            _organ_assembly_assert_reference(status, historical)
            @test PlantSimEngine._status_identity(status) !== PlantSimEngine._status_identity(historical)
        end
        for name in names
            @test PlantSimEngine.refvalue(constructed[1], name) !== PlantSimEngine.refvalue(constructed[2], name)
            @test PlantSimEngine.refvalue(constructed[2], name) !== PlantSimEngine.refvalue(constructed[3], name)
            @test PlantSimEngine.refvalue(constructed[3], name) !== PlantSimEngine.refvalue(constructed[4], name)
        end
    end

    nested = Ref(7)
    array_reference = Ref([8, 9], 2)
    payload = [10]
    named = (single=Float32(1.25), precise=BigFloat("2.5"), nested=nested, array_ref=array_reference, payload=payload)
    names, data = keys(named), values(named)
    historical = Status(NamedTuple{names}(Ref.(data)))
    constructed = (
        Status{names}(data), Status(named), Status(; named...),
        PlantSimEngine._organ_status_from_values(Val(names), data),
    )
    for status in constructed
        _organ_assembly_assert_reference(status, historical)
        @test status.nested === nested
        @test status.array_ref === array_reference
        @test PlantSimEngine.refvalue(status, :nested) !== nested
        @test PlantSimEngine.refvalue(status, :array_ref) !== array_reference
    end
    nested[] = 11
    array_reference[] = 12
    push!(payload, 13)
    for status in constructed
        @test status.nested[] == 11
        @test status.array_ref[] == 12
        @test status.payload === payload
        @test status.payload == [10, 13]
    end
    # A NamedTuple containing only carriers continues to use the inner
    # constructor, rather than treating those carriers as scientific values.
    carriers = Status((nested=nested, array_ref=array_reference))
    @test PlantSimEngine.refvalue(carriers, :nested) === nested
    @test PlantSimEngine.refvalue(carriers, :array_ref) === array_reference

    for (names, data) in (((:a,), ()), ((), (1,)), ((:a, :b), (1,)))
        historical_error = try
            Status(NamedTuple{names}(Ref.(data)))
        catch caught
            caught
        end
        actual_error = try
            Status{names}(data)
        catch caught
            caught
        end
        @test historical_error isa Exception
        @test typeof(actual_error) === typeof(historical_error)
        helper_error = try
            PlantSimEngine._organ_status_from_values(Val(names), data)
        catch caught
            caught
        end
        @test typeof(helper_error) === typeof(historical_error)
    end
end
