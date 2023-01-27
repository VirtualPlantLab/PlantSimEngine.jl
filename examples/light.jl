# This script is from https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/light/Beer.jl
# It is provided here as an example of how to write a process (light interception) and a model for its
# computation (Beer-Lambert law of light extinction). Including it as an example here 
# allows us to not have a (cyclic) dependency on PlantBiophysics.jl in the docs.

# Generate the light interception process methods:
@process "light_interception" verbose = false

"""
    Beer(k)

Beer-Lambert law for light interception.

Required inputs: `LAI` in m² m⁻².
Required meteorology data: `Ri_PAR_f`, the incident flux of atmospheric radiation in the
PAR, in W m[soil]⁻² (== J m[soil]⁻² s⁻¹).

Output: PPFD, the absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[leaf]⁻² s⁻¹.
"""
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end

"""
    run!(::Beer, object, meteo, constants=Constants(), extra=nothing)

Computes the light interception of an object using the Beer-Lambert law.

# Arguments

- `::Beer`: a Beer model, from the model list (*i.e.* m.light_interception)
- `models`: A `ModelList` struct holding the parameters for the model with
initialisations for `LAI` (m² m⁻²): the leaf area index.
- `status`: the status of the model, usually the model list status (*i.e.* m.status)
- `meteo`: meteorology structure, see [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere)
- `constants = PlantMeteo.Constants()`: physical constants. See `PlantMeteo.Constants` for more details
- `extra = nothing`: extra arguments, not used here.

# Examples

```julia
m = ModelList(Beer(0.5), status=(LAI=2.0,))

meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0)

run!(m, meteo)

m[:PPFD]
```
"""
function PlantSimEngine.run!(::Beer, models, status, meteo, constants, extra=nothing)
    status.PPFD =
        meteo.Ri_PAR_f *
        exp(-models.light_interception.k * status.LAI) *
        constants.J_to_umol
end

function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (PPFD=-Inf,)
end
