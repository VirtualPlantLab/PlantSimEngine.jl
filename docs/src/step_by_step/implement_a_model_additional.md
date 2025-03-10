# Model implementation additional notes

```@contents
Pages = ["implement_a_model_additional.md"]
Depth = 3
```

## Parametric types

In [Implementing a model](@ref model_implementation_page), the Beer model's structure was declared with a parametric type.

```julia
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

Why not force the type ? Float64 is more accurate than Float32, after all:

```julia
struct YourStruct <: AbstractLight_InterceptionModel
    k::Float64
    x::Float64
    y::Float64
    z::Int
end
```

Doing so would lose some flexibility in the way users can make use of your models. For example a user could use the `Particles` type from [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) for automatic uncertainty propagation, and this is only possible if the model type is parameterizable. Forcing a `Float64` type would render the model incompatible with `Particles`.

## Type promotion

When implementing a new model, you can do a little optional extra work to help future users.

You can add a method for type promotion. It wouldn't make any sense for the previous `Beer` example because we have only one parameter. But we can make another example with a new model that would be called `Beer2` that would take two parameters:

```julia
struct Beer2{T} <: AbstractLight_InterceptionModel
    k::T
    x::T
end
```

To add type promotion to `Beer2` we would do:

```julia
function Beer2(k,x)
    Beer2(promote(k,x)...)
end
```

!!! note
    `promote` returns a NamedTuple, which needs to be splatted for the constructor, see the [Julia docs](https://docs.julialang.org/en/v1/manual/conversion-and-promotion/#Promotion) for a more in-depth explanation, or our [Getting started with Julia](@ref) page for some links to other references discussing Julia concepts used in PlantSimEngine.

This would allow users to instantiate the model parameters using different types of inputs. For example users may write the following:

```julia
Beer2(0.6,2)
```

`Beer2` is a parametric type, with all fields sharing the same type `T`. This is the `T` in `Beer2{T}` and then in `k::T` and `x::T`. And this forces the user to give all parameters with the same type.

And in the example above, providin `0.6` for `k`, which is a `Float64`, and `2` for `x`, which is an `Int`. If you don't have type promotion, Julia will return an error because both should be either `Float64` or `Int`. That's were type promotion comes in handy, as it will convert all your inputs to a common type (when possible). In our case it will convert `2` to `2.0`.

## Other helper functions and constructors

### Default parameter values

You can simplify model usage by helping your user with default values for some parameters (if applicable). For example, in the `Beer` model a user will almost never change the value of `k`. So we can provide a default value like so:

```@example usepkg
Beer() = Beer(0.6)
```

Now the user can call `Beer` with no arguments, and `k` will default to `0.6`.

### Parameter values as kwargs

Another useful thing is the ability to instantiate your model type with keyword arguments, *i.e.* naming the arguments. You can do it by adding the following method:

```@example usepkg
Beer(;k) = Beer(k)
```

The `;` syntax indicates that subsequent arguments are provided as keyword arguments, so now we can call `Beer` like this:

```julia
Beer(k = 0.7)
```

This helps readability when there are a lot of parameters and some have default values.

### eltype

The last optional utility function to implement is a method for the `eltype` function:

```julia
Base.eltype(x::Beer{T}) where {T} = T
```

This one helps Julia know the type of the elements in the structure, and make it faster.