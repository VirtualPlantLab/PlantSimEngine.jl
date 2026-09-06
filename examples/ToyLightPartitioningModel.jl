# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "light_partitioning" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyLightPartitioningModel()

Partitions absorbed light in proportion to organ surface. This is a teaching
model, not a calculation of the light environment of an individual leaf.

# Inputs

- `aPPFD_larger_scale`: absorbed photosynthetic photon flux density at the larger
  scale, for example in μmol photons m⁻² ground s⁻¹.
- `surface`: surface of the receiving organ, in m².
- `total_surface`: sum of the organ surfaces sharing this light, in m²; must be positive.

# Outputs

- `aPPFD`: this organ's contribution, in the same units and on the same area
  basis as `aPPFD_larger_scale`. A ground-area input gives a ground-area
  contribution, not a photon flux density per unit leaf area.

The contributions sum to the supplied larger-scale value when `total_surface`
equals the sum of receiving surfaces. Use an explicit area conversion before
passing a contribution to a model that requires a leaf-area photon flux density.
"""
struct ToyLightPartitioningModel <: AbstractLight_PartitioningModel end

# Define inputs:
PlantSimEngine.inputs_(::ToyLightPartitioningModel) = (
    aPPFD_larger_scale=Required(Real),
    total_surface=Required(Real),
    surface=Required(Real),
)

# Define outputs:
PlantSimEngine.outputs_(::ToyLightPartitioningModel) = (aPPFD=-Inf,)

function PlantSimEngine.run!(::ToyLightPartitioningModel, status, environment, constants, context)
    status.aPPFD = status.aPPFD_larger_scale * status.surface / status.total_surface
end
