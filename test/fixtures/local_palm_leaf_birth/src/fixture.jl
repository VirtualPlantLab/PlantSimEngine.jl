module LocalPalmLeafBirth

import PlantSimEngine as PSE
using Dates: Day

export make_scene, prepare_scene, register_leaf!, refresh_zero!, ordinary_step!
export palm_id, leaf_ids, palm_values, leaf_values, record_values, expected_assimilation
export acquire_neighbours!, native_run!

PSE.@process "local_birth_water_supply" verbose=false
PSE.@process "local_birth_leaf_assimilation" verbose=false
PSE.@process "local_birth_palm_carbon" verbose=false

struct PalmSupply{T} <: AbstractLocal_Birth_Water_SupplyModel end
struct LeafAssimilation{T} <: AbstractLocal_Birth_Leaf_AssimilationModel
    efficiency::T
    memory::T
end
struct PalmCarbon{T} <: AbstractLocal_Birth_Palm_CarbonModel end

PSE.inputs_(::PalmSupply{T}) where {T} = (soil_water=PSE.Required(T),)
PSE.outputs_(::PalmSupply{T}) where {T} = (supply=zero(T),)
PSE.inputs_(::LeafAssimilation{T}) where {T} =
    (area=PSE.Required(T), water=PSE.Required(T), previous_assimilation=PSE.Default(zero(T)))
PSE.outputs_(::LeafAssimilation{T}) where {T} =
    (assimilation=zero(T), water_seen=zero(T), previous_seen=zero(T), visits=Int64(0))
PSE.environment_inputs_(::LeafAssimilation{T}) where {T} = (par=zero(T),)
PSE.inputs_(::PalmCarbon{T}) where {T} = (leaf_assimilations=PSE.Default(T[]),
    self_leaf_losses=PSE.Required(AbstractVector{<:Real}))
PSE.outputs_(::PalmCarbon{T}) where {T} =
    (carbon=zero(T), reserve=zero(T), leaf_count=Int64(0))

const WATER = PSE.VariableContract(unit=:fraction, basis=:palm,
    temporal=:instantaneous, aggregation=:state, extent=:intensive)
const AREA = PSE.VariableContract(unit=:m2, basis=:leaf,
    temporal=:instantaneous, aggregation=:state, extent=:extensive)
const LEAF_CARBON = PSE.VariableContract(unit=:illustrative_carbon, basis=:leaf,
    temporal=:instantaneous, aggregation=:state, extent=:extensive)
const PALM_CARBON = PSE.VariableContract(unit=:illustrative_carbon, basis=:palm,
    temporal=:instantaneous, aggregation=:total, extent=:extensive)
PSE.variable_contracts_(::PalmSupply) = (soil_water=WATER, supply=WATER)
PSE.variable_contracts_(::LeafAssimilation) =
    (area=AREA, water=WATER, previous_assimilation=LEAF_CARBON,
     assimilation=LEAF_CARBON, water_seen=WATER, previous_seen=LEAF_CARBON)
PSE.variable_contracts_(::PalmCarbon) =
    (leaf_assimilations=LEAF_CARBON, self_leaf_losses=LEAF_CARBON,
     carbon=PALM_CARBON, reserve=PALM_CARBON)

function PSE.run!(::PalmSupply, status, environment, constants, context)
    status.supply = status.soil_water
    return nothing
end
function PSE.run!(model::LeafAssimilation, status, environment, constants, context)
    status.water_seen = status.water
    status.previous_seen = status.previous_assimilation
    status.assimilation = status.area * status.water * environment.par * model.efficiency +
                          model.memory * status.previous_assimilation
    status.visits += 1
    return nothing
end
function PSE.run!(::PalmCarbon, status, environment, constants, context)
    status.carbon = sum(status.leaf_assimilations; init=zero(status.carbon)) -
                    sum(status.self_leaf_losses; init=zero(status.carbon))
    status.reserve += status.carbon
    status.leaf_count = length(status.leaf_assimilations)
    return nothing
end

palm_id(index::Integer) = index == 0 ? Int64(1) : Int64(1000 + 10index)
leaf_ids(index::Integer) = index == 0 ? (Int64(2), Int64(3)) :
                                      (palm_id(index) + 1, palm_id(index) + 2)
const NEW_LEAF = Int64(4)

palm_cells(::Type{T}, soil) where {T} =
    (soil_water=Ref(T(soil)), supply=Ref(zero(T)), carbon=Ref(zero(T)),
     reserve=Ref(zero(T)), leaf_count=Ref(Int64(0)))
leaf_cells(::Type{T}, area) where {T} =
    (area=Ref(T(area)), water=Ref(zero(T)), previous_assimilation=Ref(zero(T)),
     assimilation=Ref(zero(T)), water_seen=Ref(zero(T)), previous_seen=Ref(zero(T)),
     visits=Ref(Int64(0)))

function record(index::Integer, ::Type{T}) where {T}
    soil = index == 0 ? T(3) / T(4) : T(1) / T(2) + T(index) / T(512)
    areas = index == 0 ? (T(1), T(1) / T(2)) :
            (T(1) / T(2) + T(mod(index, 4)) / T(8),
             T(1) / T(4) + T(mod(index, 3)) / T(16))
    return (index=Int(index), id=palm_id(index), leaves=leaf_ids(index),
            palm=palm_cells(T, soil), leaf=(leaf_cells(T, areas[1]), leaf_cells(T, areas[2])))
end

"""A structural carbon-flow fixture, not a calibrated palm physiology model.

Every leaf reads only its direct Palm ancestor, its own previous assimilation,
and a common immutable environment. Every Palm sums only its own subtree.
A and its new leaf have identical IDs, initial cells and parameters for any
number of independent neighbouring palms. No selector spans the forest.
"""
function make_scene(neighbours::Integer; T::Type{<:AbstractFloat}=Float32)
    neighbours >= 0 || throw(ArgumentError("neighbours must be nonnegative"))
    records = [record(index, T) for index in 0:neighbours]
    objects = PSE.Object[PSE.Object(Int64(0); scale=:Forest, kind=:forest)]
    for r in records
        push!(objects, PSE.Object(r.id; scale=:Palm, kind=:plant,
            species=:Elaeis_guineensis, name=r.index == 0 ? "A" : "neighbour_$(r.index)",
            parent=Int64(0), status=PSE.Status(r.palm)))
        for k in 1:2
            push!(objects, PSE.Object(r.leaves[k]; scale=:Leaf, kind=:leaf,
                species=:Elaeis_guineensis, parent=r.id, status=PSE.Status(r.leaf[k])))
        end
    end
    model = PSE.CompositeModel(objects...; applications=(
        PSE.ModelSpec(PalmSupply{T}(); name=:palm_supply, on=PSE.Many(scale=:Palm),
            inputs=(soil_water=PSE.One(within=PSE.Self(), from_status=true, var=:soil_water),)),
        PSE.ModelSpec(LeafAssimilation(T(1) / T(8), T(1) / T(8));
            name=:leaf_assimilation, on=PSE.Many(scale=:Leaf),
            inputs=(:area => PSE.One(within=PSE.Self(), from_status=true, var=:area),
                :water => PSE.One(within=PSE.Ancestor(scale=:Palm), scale=:Palm,
                    application=:palm_supply, var=:supply),
                PSE.PreviousTimeStep(:previous_assimilation) => PSE.One(within=PSE.Self(),
                    application=:leaf_assimilation, var=:assimilation))),
        PSE.ModelSpec(PalmCarbon{T}(); name=:palm_carbon, on=PSE.Many(scale=:Palm),
            inputs=(leaf_assimilations=PSE.Many(within=PSE.Subtree(), scale=:Leaf,
                        application=:leaf_assimilation, var=:assimilation),
                    # The default Self scope keeps this input empty after a leaf is born.
                    self_leaf_losses=PSE.Many(scale=:Leaf, var=:loss, from_status=true))),
    ), environment=(duration=Day(1), par=T(8)))
    newborn = leaf_cells(T, T(1) / T(4))
    object = PSE.Object(NEW_LEAF; scale=:Leaf, kind=:leaf, species=:Elaeis_guineensis,
        parent=palm_id(0), status=PSE.Status(newborn))
    return (model=model, records=records, newborn=newborn, newborn_object=object,
            neighbours=Int(neighbours))
end

prepare_scene(scene; performance=false) =
    (; scene..., simulation=PSE.run!(scene.model; steps=0, outputs=:all, performance))
"""Acquire runtime neighbours before the control trajectory, using ordinary growth.

The initial prepared state contains A alone. Neither the count nor the resulting
objects are embedded in a specialised simulation type. The same helper is used
by the ordinary control and by one compiled executable with a runtime count.
"""
function acquire_neighbours!(state, neighbours::Integer)
    neighbours >= 0 || throw(ArgumentError("neighbours must be nonnegative"))
    length(state.records) == 1 && PSE.current_step(state.simulation) == 0 ||
        throw(ArgumentError("Acquire neighbours once, before the first step."))
    model = PSE.runtime_model(state.simulation)
    T = typeof(first(state.records).palm.soil_water[])
    for index in 1:neighbours
        r = record(index,T)
        PSE.register_object!(model,PSE.Object(r.id;scale=:Palm,kind=:plant,
            species=:Elaeis_guineensis,name="neighbour",parent=Int64(0),status=PSE.Status(r.palm)))
        for k in 1:2
            PSE.register_object!(model,PSE.Object(r.leaves[k];scale=:Leaf,kind=:leaf,
                species=:Elaeis_guineensis,parent=r.id,status=PSE.Status(r.leaf[k])))
        end
        push!(state.records,r)
    end
    PSE.continue!(state.simulation;steps=0)
    return (; state...,neighbours=Int(neighbours))
end

register_leaf!(state) = PSE.register_object!(PSE.runtime_model(state.simulation), state.newborn_object)
# Public zero-step continuation follows the ordinary dynamic refresh boundary.
# It refreshes bindings/cohorts/retention/requests but executes no scientific step.
refresh_zero!(state) = PSE.continue!(state.simulation; steps=0)
ordinary_step!(state) = PSE.step!(state.simulation)

palm_values(c) = (soil_water=c.soil_water[], supply=c.supply[], carbon=c.carbon[],
                  reserve=c.reserve[], leaf_count=c.leaf_count[])
leaf_values(c) = (area=c.area[], assimilation=c.assimilation[], water_seen=c.water_seen[],
                  previous_seen=c.previous_seen[], visits=c.visits[])
record_values(r) = (id=r.id, leaves=r.leaves, palm=palm_values(r.palm),
                    leaf=(leaf_values(r.leaf[1]), leaf_values(r.leaf[2])))

# Independent recurrence: no model kernel, binding or history supplies expected values.
function expected_assimilation(area, water, steps)
    value, previous = zero(area), zero(area)
    for _ in 1:steps
        previous = value
        value = area * water * 8f0 * 0.125f0 + 0.125f0 * previous
    end
    return (; value, previous)
end

function _all_record_values_ok(state)
    day = PSE.current_step(state.simulation)
    for record in state.records
        water = record.palm.soil_water[]
        expected = map(cell -> expected_assimilation(cell.area[], water, day), record.leaf)
        for index in 1:2
            cell = record.leaf[index]
            leaf_values(cell) == (area=cell.area[], assimilation=expected[index].value,
                water_seen=water, previous_seen=expected[index].previous,
                visits=Int64(day)) || return false
        end
        born = record.index == 0
        newborn = born ? expected_assimilation(state.newborn.area[], water, day - 3) : nothing
        carbon = expected[1].value + expected[2].value + (born ? newborn.value : 0f0)
        reserve = zero(water)
        for tick in 1:day
            daily = expected_assimilation(record.leaf[1].area[], water, tick).value +
                expected_assimilation(record.leaf[2].area[], water, tick).value
            if born && tick >= 4
                daily += expected_assimilation(state.newborn.area[], water, tick - 3).value
            end
            reserve += daily
        end
        palm_values(record.palm) == (soil_water=water, supply=water, carbon=carbon,
            reserve=reserve, leaf_count=Int64(born ? 3 : 2)) || return false
        if born
            leaf_values(state.newborn) == (area=state.newborn.area[],
                assimilation=newborn.value, water_seen=water,
                previous_seen=newborn.previous, visits=Int64(day - 3)) || return false
        end
    end
    return true
end

"""Run the same acquisition and local birth in ordinary and native modes.

The five nanosecond intervals exclude observations. Construction/preparation of
A occurs separately on the host, before this runtime action.
"""
function native_run!(initial, neighbours::Integer)
    started = time_ns()
    state = acquire_neighbours!(initial, neighbours)
    acquisition_ns = time_ns() - started

    started = time_ns()
    for _ in 1:3
        ordinary_step!(state)
    end
    warmup_ns = time_ns() - started

    neighbours_before = [record_values(record) for record in state.records[2:end]]
    a_before = record_values(first(state.records))
    step_before = PSE.current_step(state.simulation)

    started = time_ns()
    register_leaf!(state)
    registration_ns = time_ns() - started

    started = time_ns()
    refresh_zero!(state)
    refresh_ns = time_ns() - started

    unchanged = PSE.current_step(state.simulation) == step_before &&
        record_values(first(state.records)) == a_before
    for index in 2:length(state.records)
        unchanged &= record_values(state.records[index]) == neighbours_before[index - 1]
    end

    started = time_ns()
    ordinary_step!(state)
    ordinary_after_birth_ns = time_ns() - started

    valid = unchanged && _all_record_values_ok(state)
    timings = (acquisition_ns, warmup_ns, registration_ns, refresh_ns, ordinary_after_birth_ns)
    return (; state, ok=valid, timings)
end

end # module
