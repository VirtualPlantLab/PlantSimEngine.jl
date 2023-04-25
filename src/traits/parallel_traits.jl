"""
    DependencyTrait(T::Type)

Returns information about the eventual dependence of a model `T` to other time-steps or objects
for its computation. The dependence trait is used to determine if a model is parallelizable 
or not.

The following dependence traits are supported:

- `TimeStepDependencyTrait`: Trait that defines whether a model can be parallelizable over time-steps for its computation.
- `ObjectDependencyTrait`: Trait that defines whether a model can be parallelizable over objects for its computation.
"""
abstract type DependencyTrait end

abstract type TimeStepDependencyTrait <: DependencyTrait end
struct IsTimeStepDependent <: TimeStepDependencyTrait end
struct IsTimeStepIndependent <: TimeStepDependencyTrait end

"""
    TimeStepDependencyTrait(::Type{T})

Defines the trait about the eventual dependence of a model `T` to other time-steps for its computation. 
This dependency trait is used to determine if a model is parallelizable over time-steps or not.

The following dependency traits are supported:

- `IsTimeStepDependent`: The model depends on other time-steps for its computation, it cannot be run in parallel.
- `IsTimeStepIndependent`: The model does not depend on other time-steps for its computation, it can be run in parallel.

All models are time-step dependent by default (*i.e.* `IsTimeStepDependent`). This is probably not right for the 
majority of models, but:

1. It is the safest default, as it will not lead to incorrect results if the user forgets to override this trait
which is not the case for the opposite (i.e. `IsTimeStepIndependent`)
2. It is easy to override this trait for models that are time-step independent

# See also

- [`timestep_parallelizable`](@ref): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
- [`object_parallelizable`](@ref): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
- [`parallelizable`](@ref): Returns `true` if the model is parallelizable, and `false` otherwise.
- [`ObjectDependencyTrait`](@ref): Defines the trait about the eventual dependence of a model to other objects for its computation.

# Examples

Define a dummy process:
```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```

Define a model that is time-step independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()
```

Check if the model is parallelizable over time-steps:

```julia
timestep_parallelizable(MyModel()) # false
```

Define a model that is time-step dependent:

```julia
struct MyModel2 <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel2}) = IsTimeStepDependent()
```

Check if the model is parallelizable over time-steps:

```julia
timestep_parallelizable(MyModel()) # true
```
"""
TimeStepDependencyTrait(::Type) = IsTimeStepDependent()

"""
    timestep_parallelizable(x::T)
    timestep_parallelizable(x::DependencyGraph)

Returns `true` if the model `x` is parallelizable, i.e. if the model can be computed in parallel
over time-steps, or `false` otherwise.
    
The default implementation returns `false` for all models.
If you develop a model that is parallelizable over time-steps, you should add a method to [`ObjectDependencyTrait`](@ref)
for your model.

Note that this method can also be applied on a [`DependencyGraph`](@ref) directly, in which case it returns `true` if all
models in the graph are parallelizable, and `false` otherwise.

# See also

- [`object_parallelizable`](@ref): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
- [`parallelizable`](@ref): Returns `true` if the model is parallelizable, and `false` otherwise.
- [`TimeStepDependencyTrait`](@ref): Defines the trait about the eventual dependence of a model to other time-steps for its computation.

# Examples

Define a dummy process:
```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```

Define a model that is time-step independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()
```

Check if the model is parallelizable over objects:

```julia
timestep_parallelizable(MyModel()) # true
```
"""
timestep_parallelizable(x::T) where {T} = timestep_parallelizable(TimeStepDependencyTrait(T), x)
timestep_parallelizable(::IsTimeStepDependent, x) = false
timestep_parallelizable(::IsTimeStepIndependent, x) = true

"""
    ObjectDependencyTrait(::Type{T})

Defines the trait about the eventual dependence of a model `T` to other objects for its computation.
This dependency trait is used to determine if a model is parallelizable over objects or not.

The following dependency traits are supported:

- `IsObjectDependent`: The model depends on other objects for its computation, it cannot be run in parallel.
- `IsObjectIndependent`: The model does not depend on other objects for its computation, it can be run in parallel.

All models are object dependent by default (*i.e.* `IsObjectDependent`). This is probably not right for the
majority of models, but:

1. It is the safest default, as it will not lead to incorrect results if the user forgets to override this trait
which is not the case for the opposite (i.e. `IsObjectIndependent`)
2. It is easy to override this trait for models that are object independent

# See also

- [`timestep_parallelizable`](@ref): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
- [`object_parallelizable`](@ref): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
- [`parallelizable`](@ref): Returns `true` if the model is parallelizable, and `false` otherwise.
- [`TimeStepDependencyTrait`](@ref): Defines the trait about the eventual dependence of a model to other time-steps for its computation.

# Examples

Define a dummy process:
```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```

Define a model that is object independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```

Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # false
```

Define a model that is object dependent:

```julia
struct MyModel2 <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel2}) = IsObjectDependent()
```

Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # true
```
"""
abstract type ObjectDependencyTrait <: DependencyTrait end
struct IsObjectDependent <: ObjectDependencyTrait end
struct IsObjectIndependent <: ObjectDependencyTrait end
ObjectDependencyTrait(::Type) = IsObjectIndependent()

"""
    object_parallelizable(x::T)
    object_parallelizable(x::DependencyGraph)

Returns `true` if the model `x` is parallelizable, i.e. if the model can be computed in parallel
for different objects, or `false` otherwise. 
    
The default implementation returns `false` for all models.
If you develop a model that is parallelizable over objects, you should add a method to [`ObjectDependencyTrait`](@ref)
for your model.

Note that this method can also be applied on a [`DependencyGraph`](@ref) directly, in which case it returns `true` if all
models in the graph are parallelizable, and `false` otherwise.

# See also

- [`timestep_parallelizable`](@ref): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
- [`parallelizable`](@ref): Returns `true` if the model is parallelizable, and `false` otherwise.
- [`ObjectDependencyTrait`](@ref): Defines the trait about the eventual dependence of a model to other objects for its computation.

# Examples

Define a dummy process:
```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```

Define a model that is object independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```

Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # true
```
"""
object_parallelizable(x::T) where {T} = object_parallelizable(ObjectDependencyTrait(T), x)
object_parallelizable(::IsObjectDependent, x) = false
object_parallelizable(::IsObjectIndependent, x) = true

"""
    parallelizable(::T)
    object_parallelizable(x::DependencyGraph)

Returns `true` if the model `T` or the whole dependency graph is parallelizable, *i.e.* if the model can be computed in parallel
for different time-steps or objects. The default implementation returns `false` for all models.

# See also

- [`timestep_parallelizable`](@ref): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
- [`object_parallelizable`](@ref): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
- [`TimeStepDependencyTrait`](@ref): Defines the trait about the eventual dependence of a model to other time-steps for its computation.

# Examples

Define a dummy process:
```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```

Define a model that is parallelizable:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```

Check if the model is parallelizable:

```julia
parallelizable(MyModel()) # true
```

Or if we want to be more explicit:

```julia
timestep_parallelizable(MyModel())
object_parallelizable(MyModel())
```
"""
parallelizable(x::T) where {T} = timestep_parallelizable(x) && object_parallelizable(x)