# This script implements 3 dummy processes used for testing

# Defining a process called "process1" and a model
# that implements an algorithm (Process1Model): 
abstract type AbstractTestModel <: AbstractModel end
@gen_process_methods "process1" verbose = false
struct Process1Model <: AbstractTestModel
    a
end
PlantSimEngine.inputs_(::Process1Model) = (var1=-Inf, var2=-Inf)
PlantSimEngine.outputs_(::Process1Model) = (var3=-Inf,)
function process1!_(::Process1Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var3 = models.process1.a + status.var1 * status.var2
end

# Defining a 2nd process called "process2", and a model
# that implements an algorithm, and that depends on the first one:
@gen_process_methods "process2" verbose = false
struct Process2Model <: AbstractTestModel end
PlantSimEngine.inputs_(::Process2Model) = (var1=-Inf, var3=-Inf)
PlantSimEngine.outputs_(::Process2Model) = (var4=-Inf, var5=-Inf)
PlantSimEngine.dep(::Process2Model) = (process1=Process1Model,)
function process2!_(::Process2Model, models, status, meteo, constants=nothing, extra=nothing)
    # computing var3 using process1:
    process1!_(models.process1, models, status, meteo, constants)
    # computing var4 and var5:
    status.var4 = status.var3 * 2.0
    status.var5 = status.var4 + 1.0
end

# Defining a 3d process called "process3", and a model
# that implements an algorithm, and that depends on the second one (and
# by extension on the first one):
@gen_process_methods "process3" verbose = false
struct Process3Model <: AbstractTestModel end
PlantSimEngine.inputs_(::Process3Model) = (var4=-Inf, var5=-Inf)
PlantSimEngine.outputs_(::Process3Model) = (var4=-Inf, var6=-Inf)
PlantSimEngine.dep(::Process3Model) = (process2=Process2Model,)
function process3!_(::Process3Model, models, status, meteo, constants=nothing, extra=nothing)
    # computing var3 using process1:
    process2!_(models.process2, models, status, meteo, constants)
    # re-computing var4:
    status.var4 = status.var4 * 2.0
    status.var6 = status.var5 + status.var4
end
