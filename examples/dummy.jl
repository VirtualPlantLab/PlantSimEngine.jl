# This script implements 3 dummy processes used for testing

# Defining a process called "process1" and a model
# that implements an algorithm (Process1Model): 

PlantSimEngine.@process "process1" verbose = false

"""
    Process1Model(a)

A dummy model implementing a "process1" process for testing purposes.
"""
struct Process1Model <: AbstractProcess1Model
    a
end
PlantSimEngine.inputs_(::Process1Model) = (var1=-Inf, var2=-Inf)
PlantSimEngine.outputs_(::Process1Model) = (var3=-Inf,)
function PlantSimEngine.run!(::Process1Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var3 = models.process1.a + status.var1 * status.var2
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process1Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process1Model}) = PlantSimEngine.IsObjectIndependent()


# Defining a 2nd process called "process2", and a model
# that implements an algorithm, and that depends on the first one:
PlantSimEngine.@process "process2" verbose = false

"""
    Process2Model()

A dummy model implementing a "process2" process for testing purposes.
"""
struct Process2Model <: AbstractProcess2Model end
PlantSimEngine.inputs_(::Process2Model) = (var1=-Inf, var3=-Inf)
PlantSimEngine.outputs_(::Process2Model) = (var4=-Inf, var5=-Inf)
PlantSimEngine.dep(::Process2Model) = (process1=AbstractProcess1Model,)
function PlantSimEngine.run!(::Process2Model, models, status, meteo, constants=nothing, extra=nothing)
    # computing var3 using process1:
    PlantSimEngine.run!(models.process1, models, status, meteo, constants)
    # computing var4 and var5:
    status.var4 = status.var3 * 2.0
    status.var5 = status.var4 + 1.0 * meteo.T + 2.0 * meteo.Wind + 3.0 * meteo.Rh
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process2Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process2Model}) = PlantSimEngine.IsObjectIndependent()

# Defining a 3d process called "process3", and a model
# that implements an algorithm, and that depends on the second one (and
# by extension on the first one):
PlantSimEngine.@process "process3" verbose = false

"""
    Process3Model()

A dummy model implementing a "process3" process for testing purposes.
"""
struct Process3Model <: AbstractProcess3Model end
PlantSimEngine.inputs_(::Process3Model) = (var4=-Inf, var5=-Inf)
PlantSimEngine.outputs_(::Process3Model) = (var6=-Inf,)
PlantSimEngine.dep(::Process3Model) = (process2=Process2Model,)
function PlantSimEngine.run!(::Process3Model, models, status, meteo, constants=nothing, extra=nothing)
    # computing var3 using process1:
    PlantSimEngine.run!(models.process2, models, status, meteo, constants, extra)
    # re-computing var4:
    status.var4 = status.var4 * 2.0
    status.var6 = status.var5 + status.var4
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process3Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process3Model}) = PlantSimEngine.IsObjectIndependent()

# Defining a 4th process called "process4", and a model
# that implements an algorithm, and that computes the 
# inputs of the root of the previous ones (process3): 
PlantSimEngine.@process "process4" verbose = false

"""
    Process4Model()

A dummy model implementing a "process4" process for testing purposes.
It computes the inputs needed for the coupled processes 1-2-3.
"""
struct Process4Model <: AbstractProcess4Model end
PlantSimEngine.inputs_(::Process4Model) = (var0=-Inf,)
PlantSimEngine.outputs_(::Process4Model) = (var1=-Inf, var2=-Inf)
function PlantSimEngine.run!(::Process4Model, models, status, meteo, constants=nothing, extra=nothing)
    # computing var3 using process1:
    # re-computing var4:
    status.var1 = status.var0 + 0.01
    status.var2 = status.var1 + 0.02
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process4Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process4Model}) = PlantSimEngine.IsObjectIndependent()

# Defining a 5th process called "process5", and a model
# that implements an algorithm, and that computes other 
# variables from outputs of process 1-2-3 (soft coupling): 
PlantSimEngine.@process "process5" verbose = false

"""
    Process5Model()

A dummy model implementing a "process5" process for testing purposes.
It needs the outputs from the coupled processes 1-2-3.
"""
struct Process5Model <: AbstractProcess5Model end
PlantSimEngine.inputs_(::Process5Model) = (var5=-Inf, var6=-Inf)
PlantSimEngine.outputs_(::Process5Model) = (var7=-Inf,)
function PlantSimEngine.run!(::Process5Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var7 = status.var5 * status.var6
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process5Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process5Model}) = PlantSimEngine.IsObjectIndependent()


# Defining a 6th process called "process6", and a model
# that implements an algorithm, and that computes other 
# variables from outputs of process 5 (soft-coupling): 
PlantSimEngine.@process "process6" verbose = false

"""
    Process6Model()

A dummy model implementing a "process6" process for testing purposes.
It needs the outputs from the coupled processes 1-2-3, but also from
process 7 that is itself independant.
"""
struct Process6Model <: AbstractProcess6Model end
PlantSimEngine.inputs_(::Process6Model) = (var7=-Inf, var9=-Inf)
PlantSimEngine.outputs_(::Process6Model) = (var8=-Inf,)
function PlantSimEngine.run!(::Process6Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var8 = status.var7 + 1.0
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process6Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process6Model}) = PlantSimEngine.IsObjectIndependent()

# Defining a 7th process called "process7", and a model
# that depends on nothing but var0 so it is independant. 
# But Process6Model depends on its output, so it is a soft-coupling:
# variables from outputs of process 5 (soft-coupling):(var0=-Inf,)
PlantSimEngine.@process "process7" verbose = false

"""
    Process7Model()

A dummy model implementing a "process7" process for testing purposes.
It is independent (needs :var0 only as for Process4Model), but its outputs
are used by Process6Model, so it is a soft-coupling.
"""
struct Process7Model <: AbstractProcess7Model end
PlantSimEngine.inputs_(::Process7Model) = (var0=-Inf, var3=-Inf)
PlantSimEngine.outputs_(::Process7Model) = (var9=-Inf,)
function PlantSimEngine.run!(::Process7Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var9 = status.var0 + 1.0
end
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Process7Model}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:Process7Model}) = PlantSimEngine.IsObjectIndependent()
