# Floating-point considerations

## Investigating a discrepancy

In TODO page, a single-scale simulation was converted to an equivalent multiscale simulation, and outputs were compared. One detail that was glossed over, but worth bearing in mind when launching simulations is related to floating-point approximations.

Single-scale simulation: 

```julia
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

out_singlescale = run!(models_singlescale, meteo_day)
```

Multi-scale equivalent: 

```julia
PlantSimEngine.@process "tt_cu" verbose = false

struct ToyTt_CuModel <: AbstractTt_CuModel end

function PlantSimEngine.run!(::ToyTt_CuModel, models, status, meteo, constants, extra=nothing)
    status.TT_cu +=
        meteo.TT
end

function PlantSimEngine.inputs_(::ToyTt_CuModel)
    NamedTuple() # No input variables
end

function PlantSimEngine.outputs_(::ToyTt_CuModel)
    (TT_cu=-Inf,)
end

mapping_multiscale = Dict(
    "Scene" => ToyTt_CuModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.5),
        ToyRUEGrowthModel(0.2),
    ),
)

mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
    plant = MultiScaleTreeGraph.Node(mtg_multiscale, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))

out_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)
```

Output comparison :

```julia

computed_TT_cu_multiscale = collect(Base.Iterators.flatten(outputs_multiscale["Scene"][:TT_cu]))

is_approx_equal = length(unique(multiscale_TT_cu .≈ out_singlescale.TT_cu)) == 1
```

Why was the comparison only approximate ? Why `≈` instead of `==`?

Let's try it out:

```julia
is_perfectly_equal = length(unique(multiscale_TT_cu .== out_singlescale.TT_cu)) == 1
```

Why is this false? Let's look at the data more closely.

Looking more closely at the output, we can notice that values are identical up to timestep #105 : 

```julia
(multiscale_TT_cu .== out_singlescale.TT_cu)[104]
```

```julia
(multiscale_TT_cu .== out_singlescale.TT_cu)[105]
```

We have the values 132.33333333333331 (multi-scale) and 132.33333333333334 (single-scale). The final output values are : 2193.8166666666643 (multi-scale) and 2193.816666666666 (single-scale).

The divergence isn't huge, but in other situations or over more timesteps it could start becoming a problem.

## Floating-point summation

The reason values aren't identical, is due to the fact that many numbers do not have an exact floating point representation. A classical example is 0.3 : 

```julia
0.1 + 0.2 - 0.3
```
5.551115123125783e-17

When summing many numbers, depnding on the order in which they are summed, floating-point approximation errors may aggregate more or less quickly. 

The default summation per-timestep in our example `Toy_Tt_CuModel` was a naive summation. The `cumsum` function used in the single-scale simulation to directly compute the TT_cu uses a pairwise summation method that provides approximation error on fewer digits compared to naive summation. Errors aggregate more slowly.

In our simple example, using Float64 values, the difference wasn't significant enough to matter, but if you are writing a simulation over many timesteps or aggregating a value over many nodes, you may need to alter models to avoid numerical errors blowing up due to floating-point accuracy.

Depending on what value is being computed and the mathematical operations used, changes may range from applying a simple scale to a range of values, to significant refactoring.

TODO links