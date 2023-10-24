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