module TwoPlantAllocationExample

using Dates
using PlantSimEngine
using PlantSimEngine.Examples: AbstractCarbon_AllocationModel

export FixedFractionAllocation, DemandAllocation
export allocation_template, allocation_plant, build_allocation_comparison

"""
    FixedFractionAllocation(leaf_fraction, wood_fraction)

Allocate fixed fractions of each day's available carbon to leaves and wood,
up to their respective demands. Keep unused carbon in reserve, without
redistributing one organ's unused share to the other organ.

This is an uncalibrated teaching hypothesis. All inputs are nonnegative
daily amounts in g elemental C per plant, after any respiration costs.
Fractions must be nonnegative and sum to at most one. The example does not
model respiration, turnover, or withdrawal from existing carbon pools.
"""
struct FixedFractionAllocation{T<:Real} <: AbstractCarbon_AllocationModel
    leaf_fraction::T
    wood_fraction::T

    function FixedFractionAllocation(leaf_fraction::Real, wood_fraction::Real)
        leaf, wood = promote(float(leaf_fraction), float(wood_fraction))
        all(x -> isfinite(x) && x >= zero(x), (leaf, wood)) ||
            throw(ArgumentError("Allocation fractions must be finite and nonnegative."))
        leaf + wood <= one(leaf) ||
            throw(ArgumentError("Allocation fractions must sum to at most one."))
        return new{typeof(leaf)}(leaf, wood)
    end
end

"""
    DemandAllocation()
    DemandAllocation{Float32}()

Allocate available carbon in proportion to leaf and wood demands, up to
their combined demand. Keep any surplus in reserve. With no demand, keep
all available carbon in reserve.

This is a second uncalibrated hypothesis for the same `carbon_allocation`
process as `FixedFractionAllocation`, with the same inputs, outputs, and
units. The type parameter selects the initial output number type.
"""
struct DemandAllocation{T<:Real} <: AbstractCarbon_AllocationModel end
DemandAllocation() = DemandAllocation{Float64}()

const AllocationModel = Union{FixedFractionAllocation,DemandAllocation}

PlantSimEngine.inputs_(::AllocationModel) = (
    carbon_offer=Required(Real),
    leaf_demand=Required(Real),
    wood_demand=Required(Real),
)

function PlantSimEngine.outputs_(::Union{FixedFractionAllocation{T},DemandAllocation{T}}) where {T}
    return (
        leaf_growth=zero(T),
        wood_growth=zero(T),
        reserve_change=zero(T),
        leaf_carbon=zero(T),
        wood_carbon=zero(T),
        reserve_carbon=zero(T),
    )
end

PlantSimEngine.environment_inputs_(::AllocationModel) = NamedTuple()
PlantSimEngine.environment_outputs_(::AllocationModel) = NamedTuple()
PlantSimEngine.timestep_hint(::AllocationModel) = Day(1)

const DAILY_CARBON = VariableContract(
    unit=:g_carbon, basis=:plant, temporal=:day,
    aggregation=:total, extent=:extensive,
)
const STORED_CARBON = VariableContract(
    unit=:g_carbon, basis=:plant, temporal=:instantaneous,
    aggregation=:state, extent=:extensive,
)

PlantSimEngine.variable_contracts_(::AllocationModel) = (
    carbon_offer=DAILY_CARBON,
    leaf_demand=DAILY_CARBON,
    wood_demand=DAILY_CARBON,
    leaf_growth=DAILY_CARBON,
    wood_growth=DAILY_CARBON,
    reserve_change=DAILY_CARBON,
    leaf_carbon=STORED_CARBON,
    wood_carbon=STORED_CARBON,
    reserve_carbon=STORED_CARBON,
)

PlantSimEngine.Authoring.model_metadata(::FixedFractionAllocation) = (
    hypothesis="Fixed fractions, capped by each organ's demand; unused shares go to reserve.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.model_metadata(::DemandAllocation) = (
    hypothesis="Available carbon is shared in proportion to organ demands; surplus goes to reserve.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::FixedFractionAllocation) = (
    leaf_fraction=(
        description="Fraction of available carbon offered to leaves before the demand cap.",
        unit=:fraction, domain=(minimum=0, maximum=1),
    ),
    wood_fraction=(
        description="Fraction of available carbon offered to wood before the demand cap.",
        unit=:fraction, domain=(minimum=0, maximum=1),
    ),
)

function _check_allocation_inputs(status)
    for variable in (:carbon_offer, :leaf_demand, :wood_demand)
        value = getproperty(status, variable)
        isfinite(value) && value >= zero(value) || throw(ArgumentError(
            "`$(variable)` must be finite and nonnegative in this teaching example.",
        ))
    end
    return nothing
end

# Fixed-fraction allocation kernel
function PlantSimEngine.run!(
    model::FixedFractionAllocation,
    status,
    environment,
    constants,
    context,
)
    _check_allocation_inputs(status)
    status.leaf_growth = min(model.leaf_fraction * status.carbon_offer, status.leaf_demand)
    # The last bound prevents roundoff from creating a negative reserve.
    status.wood_growth = min(
        model.wood_fraction * status.carbon_offer,
        status.wood_demand,
        status.carbon_offer - status.leaf_growth,
    )
    status.reserve_change = status.carbon_offer - status.leaf_growth - status.wood_growth

    status.leaf_carbon += status.leaf_growth
    status.wood_carbon += status.wood_growth
    status.reserve_carbon += status.reserve_change
    return nothing
end

# Demand-based allocation kernel
function PlantSimEngine.run!(
    ::DemandAllocation,
    status,
    environment,
    constants,
    context,
)
    _check_allocation_inputs(status)
    total_demand = status.leaf_demand + status.wood_demand
    isfinite(total_demand) || throw(ArgumentError("Combined organ demand must be finite."))
    growth = min(status.carbon_offer, total_demand)
    status.leaf_growth = iszero(total_demand) ? zero(growth) :
                         min(status.leaf_demand, growth,
                             growth * (status.leaf_demand / total_demand))
    # Keep the demand caps and carbon balance even after floating-point rounding.
    status.wood_growth = min(status.wood_demand, growth - status.leaf_growth)
    status.reserve_change = status.carbon_offer - status.leaf_growth - status.wood_growth

    status.leaf_carbon += status.leaf_growth
    status.wood_carbon += status.wood_growth
    status.reserve_carbon += status.reserve_change
    return nothing
end

"""Create a reusable configuration for one plant's allocation model."""
allocation_template(model::AllocationModel) = CompositeModelTemplate((
    ModelSpec(model; name=:allocation, on=One(scale=:Plant)),
))

"""Create one plant, optionally replacing the template's allocation model."""
function allocation_plant(
    name,
    template;
    carbon_offer=10.0,
    leaf_demand=8.0,
    wood_demand=2.0,
    allocation=nothing,
)
    initial_values = Status(; carbon_offer, leaf_demand, wood_demand)
    _check_allocation_inputs(initial_values)
    return ObjectInstance(
        name,
        template;
        root=Object(name; scale=:Plant, kind=:plant, status=initial_values),
        overrides=isnothing(allocation) ? NamedTuple() : (allocation=allocation,),
    )
end

"""
    build_allocation_comparison(; fixed_model, demand_model, plant_a, plant_b)

Build two plants in one `CompositeModel`. Both receive 10 g C per day and
demands of 8 g C for leaves and 2 g C for wood by default. Override `plant_a`
or `plant_b` with a named tuple of these inputs for an independent comparison.
Each day supplies a new carbon offer and new demands; previous reserves are
kept but cannot be withdrawn. Run with `run!(model; steps=1, outputs=:all)`.
"""
function build_allocation_comparison(;
    fixed_model=FixedFractionAllocation(0.5, 0.3),
    demand_model=DemandAllocation(),
    plant_a=(carbon_offer=10.0, leaf_demand=8.0, wood_demand=2.0),
    plant_b=(carbon_offer=10.0, leaf_demand=8.0, wood_demand=2.0),
)
    template = allocation_template(fixed_model)
    return CompositeModel(
        allocation_plant(:plant_a, template; plant_a...),
        allocation_plant(:plant_b, template; plant_b..., allocation=demand_model);
        environment=(duration=Day(1),),
    )
end

end # module TwoPlantAllocationExample
