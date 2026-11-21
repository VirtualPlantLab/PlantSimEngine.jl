module ApplicationMembershipSlotChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "membership_slot_probe" verbose=false
struct SlotProbe{T} <: AbstractMembership_Slot_ProbeModel
    parameter::T
end
PSE.inputs_(::SlotProbe) = NamedTuple()
PSE.outputs_(::SlotProbe) = NamedTuple()
PSE.run!(::SlotProbe, status, environment, constants, context) = nothing

function applications()
    payloads = (1f0, 1.0, Int8(1), Int16(1), Int32(1), Int64(1))
    names = (:first, :second, :third, :fourth, :fifth, :sixth)
    return ntuple(6) do index
        ModelSpec(SlotProbe(payloads[index]); name=names[index], on=Many(scale=:Leaf))
    end
end

@testset "slot views preserve the sole reverse index and heterogeneous catalog" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf), Object(7; scale=:Leaf);
        applications=applications())
    compiled = run!(model; steps=0, outputs=:none).compiled
    @test keytype(compiled.applications_by_object) === ObjectId
    @test length(unique(typeof(application.spec.model) for application in compiled.applications)) == 6
    for id in (ObjectId(:leaf), ObjectId(7))
        view = PSE._application_membership_slots(compiled, id)
        @test view.members === compiled.applications_by_object[id]
        @test view.applications === compiled.applications_by_id
        @test collect(view) == collect(1:6)
        @test eltype(view) === Int
        seen = Tuple{Symbol,Int}[]
        PSE._foreach_object_application(compiled, id) do application
            push!(seen, (application.id, application.slot))
        end
        @test seen == [(application.id, application.slot) for application in compiled.applications]
        # The view owns no copied membership and observes the current index order.
        reverse!(view.members)
        try
            @test collect(view) == collect(6:-1:1)
        finally
            reverse!(view.members)
        end
    end
    @test isempty(PSE._application_membership_slots(compiled, ObjectId(:absent)))
    catalog = compiled.applications_by_id
    slot = parse(Int, "6")
    @test (@inferred PSE._with_metadata_entry(application -> application.id, catalog, slot)) === :sixth
    @test_throws BoundsError PSE._with_metadata_entry(identity, catalog, 0)
    @test_throws BoundsError PSE._with_metadata_entry(identity, catalog, 7)
    @test (@inferred PSE._with_metadata_entry(application -> application.id,
        catalog, Symbol(only(["sixth"])))) === :sixth
    @test PSE._with_metadata_entry(identity, catalog, :sixth) === catalog[:sixth]
    @test PSE._with_metadata_entry(identity, catalog, Int32(6)) === catalog[:sixth]
    @test_throws KeyError PSE._with_metadata_entry(identity, catalog, :missing)
    @test_throws ArgumentError PSE._application_membership_slot(catalog, deepcopy(catalog[1]))
end

@testset "closed application indexes retain the registry identity schema" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=applications())
    compiled = run!(model; steps=0, outputs=:none).compiled
    status = PSE.model_status(model, :leaf)
    closed = PSE._closed_object_family_store(model.registry.objects)
    index = PSE._applications_by_object(compiled.applications, closed)
    @test keytype(index) === ObjectId{Symbol}
    @test PSE._index_object_id(index, ObjectId(:leaf)) === ObjectId(:leaf)
    @test_throws ArgumentError PSE._index_object_id(index, ObjectId(7))
    @test index[ObjectId(:leaf)] == compiled.applications_by_object[ObjectId(:leaf)]
    @test all(left === right for (left, right) in zip(index[ObjectId(:leaf)], compiled.applications))
    @test PSE.model_status(model, :leaf) === status
end


@testset "partial catalogs use local positions and preserve exact wrapper identity" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=applications())
    compiled = run!(model; steps=0, outputs=:none).compiled
    # A partial application is a distinct membership owner with the same plan.
    sixth = compiled.applications_by_id[:sixth]
    second = compiled.applications_by_id[:second]
    partial_sixth = PSE.CompiledModelApplication(sixth.plan, ObjectId[ObjectId(:leaf)])
    partial_second = PSE.CompiledModelApplication(second.plan, ObjectId[ObjectId(:leaf)])
    partials = (partial_sixth, partial_second)
    catalog = PSE._applications_by_id(partials)
    @test catalog isa PSE.CompiledMetadataTable
    @test keys(catalog) === (:sixth, :second)
    index = PSE._applications_by_object(partials, model.registry.objects)
    members = index[ObjectId(:leaf)]
    slots = PSE.ApplicationMembershipSlots(catalog, members)
    @test collect(slots) == [1, 2]
    seen = Tuple{Symbol,Int}[]
    for slot in slots
        PSE._with_metadata_entry(catalog, slot) do application
            push!(seen, (application.id, application.slot))
        end
    end
    @test seen == [(:sixth, 6), (:second, 2)]
    @test (@inferred PSE._with_metadata_entry(application -> application.id,
        catalog, parse(Int, "2"))) === :second
    @test PSE._with_metadata_entry(identity, catalog, 1) === partial_sixth
    @test PSE._with_metadata_entry(identity, catalog, 2) === partial_second
    @test PSE._with_metadata_entry(identity, catalog, :sixth) === partial_sixth
    @test PSE._with_metadata_entry(identity, catalog, :second) === partial_second
    @test_throws ArgumentError PSE._application_membership_slot(catalog, sixth)
    @test_throws ArgumentError PSE._application_membership_slot(compiled.applications_by_id, partial_sixth)
    # Do not silently replace a partial wrapper by a canonical one with equal id.
    push!(members, sixth)
    @test_throws ArgumentError collect(slots)
    pop!(members)
    @test collect(slots) == [1, 2]
    empty_catalog = PSE._applications_by_id(())
    empty_slots = PSE.ApplicationMembershipSlots(empty_catalog, ())
    @test isempty(empty_slots)
    @test collect(empty_slots) == Int[]
    @test_throws BoundsError PSE._with_metadata_entry(identity, empty_catalog, 1)
    @test_throws KeyError PSE._with_metadata_entry(identity, empty_catalog, :missing)
    # Owner field names are ordinary metadata identities, not property forwarding.
    metadata = PSE.CompiledMetadataTable((entries=Ref(1), length=Ref(2f0)))
    @test PSE._with_metadata_entry(identity, metadata, :entries) === metadata[:entries]
    @test PSE._with_metadata_entry(identity, metadata, :length) === metadata[:length]
end

end
