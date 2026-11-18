module LocalLeafBirthChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
include(joinpath(@__DIR__, "fixtures", "local_palm_leaf_birth", "src", "fixture.jl"))
using .LocalPalmLeafBirth

const BIOLOGICAL_FIELDS = (:soil_water, :supply, :carbon, :reserve, :leaf_count,
    :area, :assimilation, :water_seen, :previous_seen, :visits)

function retained_history(simulation, ids)
    return Dict(key => deepcopy(collect(stream)) for (key, stream) in outputs(simulation)
        if key[2].value in ids)
end

function snapshot(state, ids)
    simulation = state.simulation
    topology = Dict(id => let object = model_object(simulation, id)
        (parent=isnothing(object.parent) ? nothing : object.parent.value,
            children=[child.value for child in object.children], scale=object.scale,
            kind=object.kind, species=object.species, name=object.name)
    end for id in ids)
    return (step=current_step(simulation), topology=topology,
        states=Dict(id => final_state(simulation, id) for id in ids),
        history=retained_history(simulation, ids))
end

function biological_references(state, ids)
    return [(id=id, variable=name,
        reference=PSE.refvalue(model_status(state.simulation, id), name))
        for id in ids for name in keys(model_status(state.simulation, id))
        if name in BIOLOGICAL_FIELDS]
end

references_match(state, previous) = all(previous) do entry
    PSE.refvalue(model_status(state.simulation, entry.id), entry.variable) === entry.reference
end

function numeric_mismatches(state; born=false)
    day = current_step(state.simulation)
    mismatches = Int64[]
    for record in state.records
        water = record.palm.soil_water[]
        expected = map(cell -> expected_assimilation(cell.area[], water, day), record.leaf)
        matches = all(1:2) do index
            cell, actual = record.leaf[index], expected[index]
            leaf_values(cell) == (area=cell.area[], assimilation=actual.value,
                water_seen=water, previous_seen=actual.previous, visits=Int64(day))
        end
        newborn = born && record.index == 0 ?
            expected_assimilation(state.newborn.area[], water, day - 3) : nothing
        carbon = expected[1].value + expected[2].value +
            (isnothing(newborn) ? 0f0 : newborn.value)
        reserve = 0f0
        for tick in 1:day
            contribution = expected_assimilation(record.leaf[1].area[], water, tick).value +
                expected_assimilation(record.leaf[2].area[], water, tick).value
            if born && record.index == 0 && tick >= 4
                contribution += expected_assimilation(state.newborn.area[], water, tick - 3).value
            end
            reserve += contribution
        end
        matches &= palm_values(record.palm) == (soil_water=water, supply=water,
            carbon=carbon, reserve=reserve, leaf_count=Int64(isnothing(newborn) ? 2 : 3))
        if !isnothing(newborn)
            matches &= leaf_values(state.newborn) == (area=state.newborn.area[],
                assimilation=newborn.value, water_seen=water,
                previous_seen=newborn.previous, visits=Int64(day - 3))
        end
        matches || push!(mismatches, record.id)
    end
    return mismatches
end

function selections_match(state; born=false)
    model = runtime_model(state.simulation)
    for record in state.records
        expected = born && record.index == 0 ? [record.leaves..., Int64(4)] : collect(record.leaves)
        selected = resolve_object_ids(model, Many(Subtree(); scale=:Leaf); context=record.id)
        [id.value for id in selected] == expected || return false
        for leaf in expected
            ancestor = only(resolve_object_ids(model,
                One(Ancestor(scale=:Palm); scale=:Palm); context=leaf))
            ancestor.value == record.id || return false
            model_object(model, leaf).parent.value == record.id || return false
        end
    end
    return true
end

function check_birth(neighbours)
    initial = prepare_scene(make_scene(0))
    initial_a = snapshot(initial, Int64[1, 2, 3])
    state = acquire_neighbours!(initial, neighbours)
    simulation = state.simulation
    @test current_step(simulation) == 0
    @test length(state.records) == neighbours + 1
    @test snapshot(state, Int64[1, 2, 3]) == initial_a
    for _ in 1:3
        ordinary_step!(state)
    end
    @test current_step(simulation) == 3
    @test isempty(numeric_mismatches(state))
    @test selections_match(state)
    ids = Int64[r.id for r in state.records]
    append!(ids, (id for r in state.records for id in r.leaves))
    neighbour_ids = [id for id in ids if !(id in (Int64(1), Int64(2), Int64(3)))]
    previous_neighbours = snapshot(state, neighbour_ids)
    previous_a = snapshot(state, Int64[1, 2, 3])
    previous_biology = record_values(first(state.records))
    previous_refs = biological_references(state, ids)
    previous_streams = Dict(key => stream for (key, stream) in outputs(simulation))

    register_leaf!(state)
    refresh_zero!(state)
    @test current_step(simulation) == 3
    @test snapshot(state, neighbour_ids) == previous_neighbours
    @test record_values(first(state.records)) == previous_biology
    @test retained_history(simulation, Int64[1, 2, 3]) == previous_a.history
    @test references_match(state, previous_refs)
    @test all(outputs(simulation)[key] === stream for (key, stream) in previous_streams)
    @test selections_match(state; born=true)
    @test state.newborn.visits[] == 0
    # A's live Many input changes membership, while its biological cells do not advance.
    carrier = model_status(simulation, Int64(1)).leaf_assimilations
    expected_refs = [PSE.refvalue(model_status(simulation, id), :assimilation) for id in Int64[2, 3, 4]]
    @test length(carrier) == length(parent(carrier)) == 3
    @test all(reference === expected for (reference, expected) in zip(parent(carrier), expected_refs))
    @test collect(carrier) == [first(state.records).leaf[1].assimilation[],
        first(state.records).leaf[2].assimilation[], 0f0]
    after_refresh_a = snapshot(state, Int64[1, 2, 3, 4])

    ordinary_step!(state)
    @test current_step(simulation) == 4
    @test isempty(numeric_mismatches(state; born=true))
    @test references_match(state, previous_refs)
    @test all(outputs(simulation)[key] === stream for (key, stream) in previous_streams)
    # Neighbours execute their normal fourth day, retaining their complete old prefixes.
    following = snapshot(state, neighbour_ids)
    @test all(previous_neighbours.history) do (key, samples)
        current = following.history[key]
        length(current) == length(samples) + 1 && current[1:end-1] == samples &&
            last(current)[2] === getproperty(following.states[key[2].value], key[3]) &&
            (isempty(samples) || last(current)[1] > last(samples)[1])
    end
    return (before=previous_a, after_refresh=after_refresh_a,
        after_step=snapshot(state, Int64[1, 2, 3, 4]))
end

@testset "a local leaf birth preserves independent palms and previous-step inputs" begin
    alone = check_birth(0)
    surrounded = check_birth(100)
    @test alone == surrounded
end

end # module
