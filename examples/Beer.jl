# This script is from https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/light/Beer.jl
# It is provided here as an example of how to write a process (light interception) and a model for its
# computation (Beer-Lambert law of light extinction). Including it as an example here 
# allows us to not have a (cyclic) dependency on PlantBiophysics.jl in the docs.

# Generate the light interception process methods:
PlantSimEngine.@process "light_interception" verbose = false

"""
    Beer(k)

Beer-Lambert law for light interception.

Required inputs: `LAI` in m² m⁻².
Required meteorology data: `Ri_PAR_f`, the incident flux of atmospheric radiation in the
PAR, in W m[soil]⁻² (== J m[soil]⁻² s⁻¹).

Output: aPPFD, the absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[leaf]⁻² s⁻¹.
"""
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end


"""
    run!(model::Beer, status, environment, constants=Constants(), context=nothing)

Computes the photosynthetic photon flux density (`aPPFD`, µmol m⁻² s⁻¹) absorbed by an 
object using the incoming PAR radiation flux (`Ri_PAR_f`, W m⁻²) and the Beer-Lambert law
of light extinction.

# Arguments

- `model`: the current Beer model instance.
- `status`: the status of the model, usually the model list status (*i.e.* m.status)
- `environment`: sampled environment, such as an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) row
- `constants = PlantMeteo.Constants()`: physical constants. See `PlantMeteo.Constants` for more details
- `context = nothing`: runtime context, not used here.

# Examples

```julia
model = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    id=:leaf,
    scale=:Leaf,
    environment=Atmosphere(
        T=20.0,
        Wind=1.0,
        P=101.3,
        Rh=0.65,
        Ri_PAR_f=300.0,
        duration=Hour(1),
    ),
)
run!(model)
only(model_objects(model; scale=:Leaf)).status.aPPFD
```
"""
function PlantSimEngine.run!(model::Beer, status, meteo, constants, extra=nothing)
    status.aPPFD =
        meteo.Ri_PAR_f *
        (1.0 - exp(-model.k * status.LAI)) *
        constants.J_to_umol
end

function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=-Inf,)
end


"""
    fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)

Compute the `k` parameter of the Beer-Lambert law from measurements.

# Arguments

- `::Type{Beer}`: the model type
- `df`: a `DataFrame` with the following columns:
    - `aPPFD`: the measured absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[leaf]⁻² s⁻¹
    - `LAI`: the measured leaf area index in m² m⁻²
    - `Ri_PAR_f`: the measured incident flux of atmospheric radiation in the PAR, in W m[soil]⁻² (== J m[soil]⁻² s⁻¹)

# Examples

Import the example models defined in the `Examples` sub-module:

```julia
using PlantSimEngine
using PlantSimEngine.Examples
```

Create a model list with a Beer model, and fit it to the data:

```julia
model = CompositeModel(
    Beer(0.6);
    status=(LAI=2.0,),
    id=:leaf,
    scale=:Leaf,
    environment=meteo,
)
run!(model)
leaf = only(model_objects(model; scale=:Leaf))
df = DataFrame(aPPFD=leaf.status.aPPFD, LAI=leaf.status.LAI, Ri_PAR_f=meteo.Ri_PAR_f[1])
fit(Beer, df)
```
"""
function PlantSimEngine.fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)
    k = Statistics.mean(-log.(1 .- df.aPPFD ./ (J_to_umol .* df.Ri_PAR_f)) ./ df.LAI)
    return (k=k,)
end
