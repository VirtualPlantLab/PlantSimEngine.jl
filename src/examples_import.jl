"""
    import_multiscale_example()

Import the examples used in the documentation for a set of multiscale models.
The models can be found in the `examples` folder of the package, and are stored 
in the following files:

- `ToyAssimModel.jl`
- `ToyCDemandModel.jl`
- `ToyCAllocationModel.jl`
- `ToySoilModel.jl`

# Examples

```jl
using PlantSimEngine

import_multiscale_example()
```
"""
function import_multiscale_example()
    include(joinpath(@__DIR__, "../examples/ToyAssimModel.jl"))
    include(joinpath(@__DIR__, "../examples/ToyCDemandModel.jl"))
    include(joinpath(@__DIR__, "../examples/ToyCAllocationModel.jl"))
    include(joinpath(@__DIR__, "../examples/ToySoilModel.jl"))
end



"""
    import_mtg_example()

Returns an example multiscale tree graph (MTG) with a scene, a soil, and a plant with two internodes and two leaves.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

```jldoctest
julia> PlantSimEngine.import_mtg_example()
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