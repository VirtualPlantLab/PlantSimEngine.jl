# This script is from https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/light/Beer.jl
# It is provided here as an example of how to write a process (light interception) and a model for its
# computation (Beer-Lambert law of light extinction). Including it as an example here 
# allows us to not have a (cyclic) dependency on PlantBiophysics.jl in the docs.

# Generate the light interception process methods:
PlantSimEngine.@process "light_interception" verbose = false

"""
    Beer(k)

Beer-Lambert law for light interception.

Required inputs: `LAI` in m[leaf]² m[ground]⁻².
Required environment input: `Ri_PAR_f`, the incident flux of atmospheric radiation in the
PAR, in W m[ground]⁻² (== J m[ground]⁻² s⁻¹).

Output: `aPPFD`, the canopy-absorbed Photosynthetic Photon Flux Density in
μmol[PAR] m[ground]⁻² s⁻¹. It is not a mean leaf-area-basis PPFD.
"""
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end


"""
    run!(model::Beer, status, environment, constants, context)

Computes the canopy-absorbed photosynthetic photon flux density (`aPPFD`,
µmol[PAR] m[ground]⁻² s⁻¹) from the incoming PAR radiation flux (`Ri_PAR_f`,
W m[ground]⁻²) and the Beer-Lambert law of light extinction.

# Arguments

- `model`: the current Beer model instance.
- `status`: the application-local view of the target [`Object`](@ref) status.
- `environment`: sampled environment, such as an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) row.
- `constants`: physical constants supplied by the [`CompositeModel`](@ref) run.
- `context`: runtime context; this kernel does not use it.

# Examples

```julia
model = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    id=:plant,
    scale=:Plant,
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
only(model_objects(model; scale=:Plant)).status.aPPFD
```
"""
function PlantSimEngine.run!(model::Beer, status, environment, constants, context)
    status.aPPFD =
        environment.Ri_PAR_f *
        (1.0 - exp(-model.k * status.LAI)) *
        constants.J_to_umol
end

function PlantSimEngine.inputs_(::Beer)
    (LAI=Required(Real),)
end

function PlantSimEngine.outputs_(model::Beer)
    (aPPFD=oftype(float(model.k), -Inf),)
end

PlantSimEngine.environment_inputs_(::Beer) = (Ri_PAR_f=0.0,)


"""
    fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)

Compute the `k` parameter of the Beer-Lambert law from measurements.

# Arguments

- `::Type{Beer}`: the model type
- `df`: a `DataFrame` with the following columns:
    - `aPPFD`: canopy-absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[ground]⁻² s⁻¹
    - `LAI`: leaf area index in m[leaf]² m[ground]⁻²
    - `Ri_PAR_f`: incident PAR flux in W m[ground]⁻² (== J m[ground]⁻² s⁻¹)

`aPPFD` and `Ri_PAR_f * J_to_umol` must use the same ground-area basis.
`LAI` and the converted incident flux must be finite and strictly positive,
and the implied absorbed fraction must satisfy `0 ≤ f_abs < 1`.

# Examples

Import the example models defined in the `Examples` sub-module:

```julia
using PlantSimEngine, PlantMeteo, DataFrames
using PlantSimEngine.Examples
```

Create a `CompositeModel` with one canopy model on a plant object, then fit
`Beer` to the data:

```julia
meteo = Atmosphere(
    T=20.0,
    Wind=1.0,
    P=101.3,
    Rh=0.65,
    Ri_PAR_f=300.0,
)
model = CompositeModel(
    Beer(0.6);
    status=(LAI=2.0,),
    id=:plant,
    scale=:Plant,
    environment=meteo,
)
simulation = run!(model)
plant = final_state(simulation, One(scale=:Plant))
df = DataFrame(
    aPPFD=[plant.aPPFD],
    LAI=[plant.LAI],
    Ri_PAR_f=[meteo.Ri_PAR_f[1]],
)
Evaluation.fit(Beer, df)
```
"""
function PlantSimEngine.Evaluation.fit(
    ::Type{Beer},
    df;
    J_to_umol=PlantMeteo.Constants().J_to_umol,
)
    (J_to_umol isa Real && isfinite(J_to_umol) && J_to_umol > 0) || throw(
        DomainError(
            J_to_umol,
            "Beer fit requires a finite J_to_umol > 0; got $(repr(J_to_umol))",
        ),
    )

    k_observations = map(eachindex(df.LAI, df.Ri_PAR_f, df.aPPFD)) do row
        lai = df.LAI[row]
        (lai isa Real && isfinite(lai) && lai > 0) || throw(
            DomainError(
                lai,
                "Beer fit requires finite LAI > 0 at row $(row); got $(repr(lai))",
            ),
        )

        incident_par = df.Ri_PAR_f[row]
        (incident_par isa Real && isfinite(incident_par) && incident_par > 0) || throw(
            DomainError(
                incident_par,
                "Beer fit requires finite Ri_PAR_f > 0 at row $(row); " *
                "got $(repr(incident_par))",
            ),
        )

        incident_ppfd = incident_par * J_to_umol
        (incident_ppfd isa Real && isfinite(incident_ppfd) && incident_ppfd > 0) || throw(
            DomainError(
                incident_ppfd,
                "Beer fit requires finite incident PAR > 0 at row $(row) to define " *
                "an absorbed fraction; got $(repr(incident_ppfd))",
            ),
        )

        f_abs = df.aPPFD[row] / incident_ppfd
        (f_abs isa Real && isfinite(f_abs) && 0 <= f_abs < 1) || throw(
            DomainError(
                f_abs,
                "Beer fit requires an absorbed fraction in [0, 1) at row $(row); " *
                "got $(repr(f_abs))",
            ),
        )

        -log1p(-f_abs) / lai
    end
    isempty(k_observations) && throw(
        ArgumentError("Beer fit requires at least one observation"),
    )
    k = Statistics.mean(k_observations)
    return (k=k,)
end
