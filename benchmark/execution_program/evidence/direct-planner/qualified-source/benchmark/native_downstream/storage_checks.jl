# Included in NativeDownstreamExperiment. Root runs all Julia through Kaimon.
using Test
using MultiScaleTreeGraph

function native_storage_checks()
    @testset "Canonical native storage allocates owned scalars and preserves aliases" begin
        for T in (Float32, Float64, Int)
            storage = PSE.NativeColumnStorage()
            external = Ref(T(7))
            # The reference-only NamedTuple constructor preserves the external
            # carrier; keyword construction deliberately treats inputs as values.
            supplied = PSE.Status((external=external,))
            model = PSE.CompositeModel(
                PSE.Object(:one; status=(x=T(1), y=T(2), alias=external)),
                PSE.Object(:two; status=(x=T(3), y=T(4), alias=external)),
                PSE.Object(:given; status=supplied),
                PSE.Object(:carriers; status=(alias=external,));
                status_storage=storage,
            )
            one = PSE.model_object(model, :one).status
            two = PSE.model_object(model, :two).status
            @test propertynames(one) === (:x, :y, :alias)
            @test PSE.refvalue(one, :x) isa Base.RefArray{T}
            @test getfield(PSE.refvalue(one, :x), :x) ===
                  getfield(PSE.refvalue(two, :x), :x)
            @test one.alias === external
            @test PSE.model_object(model, :given).status === supplied
            @test PSE.refvalue(supplied, :external) === external
            @test PSE.refvalue(PSE.model_object(model, :carriers).status, :alias) === external
            @test getfield(PSE.refvalue(one, :x), :i) == 1
            @test getfield(PSE.refvalue(two, :x), :i) == 2
            first_reference = PSE.refvalue(one, :x)
            PSE.register_object!(model, PSE.Object(:three;
                status=(x=T(5), y=T(6), alias=external)))
            @test PSE.refvalue(one, :x) === first_reference
            first_reference[] = T(9)
            @test one.x === T(9)
            PSE.remove_object!(model, :two)
            @test one.x === T(9)
            @test PSE.model_object(model, :three).status.x === T(5)
            external[] = T(11)
            @test one.alias[] === T(11)
            @test PSE.model_object(model, :three).status.alias[] === T(11)
            @test PSE.native_storage_report(model).active_native_fields == 4
            removed_ref = PSE.refvalue(two, :x)
            PSE.register_object!(model, PSE.Object(:two;
                status=(x=T(13), y=T(14), alias=external)))
            @test two.x === T(3)
            @test PSE.refvalue(two, :x) === removed_ref
            @test PSE.model_object(model, :two).status.x === T(13)
            @test getfield(PSE.refvalue(PSE.model_object(model, :two).status, :x), :i) >
                  getfield(removed_ref, :i)
            @test_throws ArgumentError PSE.CompositeModel(PSE.Object(:other;
                status=(x=T(2),)); status_storage=storage)
        end

        storage = PSE.NativeColumnStorage()
        mutable_value = [1.0]
        model = PSE.CompositeModel(
            PSE.Object(1; status=(x=1.0f0, mutable=mutable_value, big=big"1.25")),
            PSE.Object(2; status=(x=2.0, mutable=[2.0], big=big"2.5"));
            status_storage=storage,
        )
        @test PSE.model_object(model, 1).status.x isa Float32
        @test PSE.model_object(model, 2).status.x isa Float64
        @test PSE.model_object(model, 1).status.mutable === mutable_value
        @test PSE.model_object(model, 1).status.big isa BigFloat
        @test PSE.refvalue(PSE.model_object(model, 1).status, :big) isa Base.RefValue

        string_status = Dict("x" => 1.0f0, "count" => 2)
        dict_model = PSE.CompositeModel(PSE.Object(:dict; status=string_status);
            status_storage=PSE.NativeColumnStorage())
        @test Set(propertynames(PSE.model_object(dict_model, :dict).status)) == Set((:x, :count))
        @test_throws ArgumentError PSE.CompositeModel(PSE.Object(:bad;
            status=Dict(1 => 1.0)); status_storage=PSE.NativeColumnStorage())
        @test_throws ArgumentError PSE.CompositeModel(PSE.Object(:duplicate;
            status=Dict{Any,Any}(:x => 1.0, "x" => 2.0));
            status_storage=PSE.NativeColumnStorage())

        promoted = PSE.CompositeModel(PSE.Object(:promoted; status=(x=1.0,));
            status_storage=PSE.NativeColumnStorage(),
            type_promotion=Dict(Float64 => Float32))
        @test PSE.model_object(promoted, :promoted).status.x === 1.0f0
        @test PSE.refvalue(PSE.model_object(promoted, :promoted).status, :x) isa Base.RefArray{Float32}

        root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Root, 1, 0))
        external = Ref(3.0f0)
        mtg_model = PSE.CompositeModel(root;
            status=_ -> (x=1.0f0,), status_storage=PSE.NativeColumnStorage())
        newborn = PSE.add_organ!(root, mtg_model, :+, :Unit, 1;
            initial_status=(x=2.0f0, alias=external))
        @test newborn === PSE.model_status(mtg_model, PSE.source_node(mtg_model,
            PSE.object_id(mtg_model, newborn)))
        @test PSE.refvalue(newborn, :x) isa Base.RefArray{Float32}
        @test newborn.alias === external
        external[] = 8.0f0
        @test newborn.alias[] === 8.0f0
    end
    return (passed=true, tested_types=(:Float32, :Float64, :Int, :BigFloat),
        supplied_references_preserved=true, newborn_native_before_refresh=true)
end
