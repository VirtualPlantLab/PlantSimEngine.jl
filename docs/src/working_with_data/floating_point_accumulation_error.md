# Floating-point considerations

```@setup usepkg
using PlantSimEngine
using PlantSimEngine.Examples
using PlantMeteo, MultiScaleTreeGraph, CSV
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

out_singlescale = run!(models, meteo_day)
```
## Investigating a discrepancy

In the [Converting a single-scale simulation to multi-scale](@ref) page, a single-scale simulation was converted to an equivalent multiscale simulation, and outputs were compared. One detail that was glossed over, but important to bear in mind as a PlantSimEngine user is related to floating-point approximations.

### Single-scale simulation

```@example usepkg
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models_singlescale = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

outputs_singlescale = run!(models_singlescale, meteo_day)
```

### Multi-scale equivalent 

```@example usepkg
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
    (TT_cu=0.0,)
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

outputs_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)
```

### Output comparison

```@setup usepkg
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

mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 0, 0),)
    plant = MultiScaleTreeGraph.Node(mtg_multiscale, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))

outputs_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)
```

```@example usepkg

computed_TT_cu_multiscale = [outputs_multiscale["Scene"][i].TT_cu for i in 1:length(outputs_multiscale["Scene"])]
is_approx_equal = length(unique(computed_TT_cu_multiscale .≈ outputs_singlescale.TT_cu)) == 1
```

Why was the comparison only approximate ? Why `≈` instead of `==`?

Let's try it out. What if write instead:

```@example usepkg
computed_TT_cu_multiscale = [outputs_multiscale["Scene"][i].TT_cu for i in 1:length(outputs_multiscale["Scene"])]
is_perfectly_equal = length(unique(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)) == 1
```

Why is this false? Let's look at the data.

Looking more closely at the output, we can notice that values are identical up to timestep #105 : 

```@example usepkg
(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)[104]
```

```@example usepkg
(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)[105]
```

We have the values 132.33333333333331 (multi-scale) and 132.33333333333334 (single-scale). The final output values are : 2193.8166666666643 (multi-scale) and 2193.816666666666 (single-scale).

The divergence isn't huge, but in other situations or over more timesteps it could start becoming a problem.

## Floating-point summation

The reason values aren't identical, is due to the fact that many numbers do not have an exact floating point representation. A classical example is the fact that [0.1 + 0.2 != 0.3](https://blog.reverberate.org/2016/02/06/floating-point-demystified-part2.html) : 

```@example usepkg
println(0.1 + 0.2 - 0.3)
```

When summing many numbers, depnding on the order in which they are summed, floating-point approximation errors may aggregate more or less quickly. 

The default summation per-timestep in our example `Toy_Tt_CuModel` was a naive summation. The `cumsum` function used in the single-scale simulation to directly compute the TT_cu uses a pairwise summation method that provides approximation error on fewer digits compared to naive summation. Errors aggregate more slowly.

In our simple example, using Float64 values, the difference wasn't significant enough to matter, but if you are writing a simulation over many timesteps or aggregating a value over many nodes, you may need to alter models to avoid numerical errors blowing up due to floating-point accuracy.

Depending on what value is being computed and the mathematical operations used, changes may range from applying a simple scale to a range of values, to significant refactoring.


## Other links related to floating-point numerical concerns

Note that many of the examples in these blogposts discuss Float32 accuracy. Float64 values have several extra precision bits to work.

A series of blog posts on floating-point accuracy: [https://randomascii.wordpress.com/2012/02/25/comparing-floating-point-numbers-2012-edition/](https://randomascii.wordpress.com/2012/02/25/comparing-floating-point-numbers-2012-edition/)
Floating-Point Visually Explained : [https://fabiensanglard.net/floating_point_visually_explained/](https://randomascii.wordpress.com/2012/02/25/comparing-floating-point-numbers-2012-edition/)
Examples of floating point problems: [https://jvns.ca/blog/2023/01/13/examples-of-floating-point-problems/](https://randomascii.wordpress.com/2012/02/25/comparing-floating-point-numbers-2012-edition/)

Relating specifically to floating-point sums:

Pairwise summation: [https://en.wikipedia.org/wiki/Pairwise_summation](https://en.wikipedia.org/wiki/Pairwise_summation)
Kahan summation: [https://en.wikipedia.org/wiki/Kahan_summation_algorithm](https://en.wikipedia.org/wiki/Kahan_summation_algorithm)
Taming Floating-Point Sums: [https://orlp.net/blog/taming-float-sums/](https://orlp.net/blog/taming-float-sums/)