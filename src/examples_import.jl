"""
A sub-module with example models.

Examples used in the documentation for a set of multiscale models.
The models can be found in the `examples` folder of the package, and are stored 
in the following files:

- `ToyAssimModel.jl`
- `ToyCDemandModel.jl`
- `ToyCAllocationModel.jl`
- `ToySoilModel.jl`

# Examples

```jl
using PlantSimEngine
using PlantSimEngine.Examples
ToyAssimModel()
```
"""
module Examples

using PlantSimEngine, MultiScaleTreeGraph, PlantMeteo, Statistics

include(joinpath(@__DIR__, "../examples/dummy.jl"))
include(joinpath(@__DIR__, "../examples/ToyDegreeDays.jl"))
include(joinpath(@__DIR__, "../examples/Beer.jl"))
include(joinpath(@__DIR__, "../examples/ToyLAIModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyAssimModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyCDemandModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyAssimGrowthModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyRUEGrowthModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyCAllocationModel.jl"))
include(joinpath(@__DIR__, "../examples/ToySoilModel.jl"))
include(joinpath(@__DIR__, "../examples/ToyInternodeEmergence.jl"))


"""
    import_mtg_example()

Returns an example multiscale tree graph (MTG) with a scene, a soil, and a plant with two internodes and two leaves.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine.Examples
```

```jldoctest mylabel
julia> import_mtg_example()
/ 1: Scene
├─ / 2: Soil
└─ + 3: Plant
   └─ / 4: Internode
      ├─ + 5: Leaf
      └─ < 6: Internode
         └─ + 7: Leaf
```
"""
function import_mtg_example()
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1))
    plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode1 = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    internode2 = MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    return mtg
end

# Processes:
export AbstractProcess1Model, AbstractProcess2Model, AbstractProcess3Model
export AbstractProcess4Model, AbstractProcess5Model, AbstractProcess6Model
export AbstractProcess7Model
export AbstractLight_InterceptionModel, AbstractLai_DynamicModel, AbstractDegreedaysModel
export AbstractPhotosynthesisModel, AbstractCarbon_AllocationModel, AbstractCarbon_DemandModel
export AbstractSoil_WaterModel, AbstractGrowthModel
export AbstractOrgan_EmergenceModel

# Models:
export Beer, ToyLAIModel, ToyDegreeDaysCumulModel
export ToyAssimModel, ToyCAllocationModel, ToyCDemandModel, ToySoilWaterModel
export ToyAssimGrowthModel, ToyRUEGrowthModel
export Process1Model, Process2Model, Process3Model, Process4Model, Process5Model
export Process6Model, Process7Model

export ToyInternodeEmergence
export import_mtg_example
end