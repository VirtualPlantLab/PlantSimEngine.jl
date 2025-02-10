
# Specific configurations that trigger specific codepaths, or relate to, say, past bugs exposed in XPalm over time
# Usually have some subtle coupling quirk that requires careful handling in the dependency graph
# The outputs and meteo values are irrelevant, those are here as guards that are likely to break if a larger rework
# fails to take those corner-cases into account, and more quickly checked than XPalm

###############################################################################################################
## Multi-Scale setup with a hard dependency calling another hard dependency
###############################################################################################################

# relates to #77 and #99

PlantSimEngine.@process "Msg3Lvl_amont" verbose = false 
PlantSimEngine.@process "Msg3Lvl_amont2" verbose = false 
PlantSimEngine.@process "Msg3Lvl_echelle1" verbose = false 
PlantSimEngine.@process "Msg3Lvl_echelle2" verbose = false 
PlantSimEngine.@process "Msg3Lvl_echelle3" verbose = false 
PlantSimEngine.@process "Msg3Lvl_aval" verbose = false 
PlantSimEngine.@process "Msg3Lvl_aval2" verbose = false 

# Roots : amont and amont2
# amont2 points to aval
# aval has a hard dependency, aval2
# ech3 is a hard dependency of ech2, itself a hard dependency of ech1
# all 3 use variables from amont, making amont a soft dependency of ech1

# aval makes use of variables from amont2, aval2, ech1 and ech3

#################

struct Msg3LvlScaleAmontModel <: AbstractMsg3Lvl_AmontModel
end

function PlantSimEngine.inputs_(::Msg3LvlScaleAmontModel)
    (a = -Inf,)
end

function PlantSimEngine.outputs_(::Msg3LvlScaleAmontModel)
    (b = -Inf, c = -Inf)
end

function PlantSimEngine.run!(::Msg3LvlScaleAmontModel, models, status, meteo, constants=nothing, extra_args=nothing)
    status.b = status.a
    status.c = 1.0
end

#################

struct Msg3LvlScaleAmont2Model <: AbstractMsg3Lvl_Amont2Model
end

function PlantSimEngine.inputs_(::Msg3LvlScaleAmont2Model)
    (a2 = -Inf,)
end

function PlantSimEngine.outputs_(::Msg3LvlScaleAmont2Model)
    (b2 = -Inf,)
end

function PlantSimEngine.run!(::Msg3LvlScaleAmont2Model, models, status, meteo, constants=nothing, extra_args=nothing)
    status.b2 = status.a2 + 1.0
end

#################

struct Msg3LvlScaleEchelle3Model <: AbstractMsg3Lvl_Echelle3Model
end

function PlantSimEngine.inputs_(::Msg3LvlScaleEchelle3Model)
    #(b = -Inf, 
    (c = -Inf,)
end

function PlantSimEngine.outputs_(::Msg3LvlScaleEchelle3Model)
    (e3 = -Inf, f3 = -Inf)
end

function PlantSimEngine.run!(::Msg3LvlScaleEchelle3Model, models, status, meteo, constants=nothing, extra_args=nothing)
    status.e3 = 1.0#status.c>
    status.f3 = 1.0
end

#################

struct Msg3LvlScaleEchelle2Model <: AbstractMsg3Lvl_Echelle2Model
end


function PlantSimEngine.inputs_(::Msg3LvlScaleEchelle2Model)
    (c = -Inf, e3 = -Inf, f3 = -Inf)
end

function PlantSimEngine.outputs_(::Msg3LvlScaleEchelle2Model)
    (e2 = -Inf, f2 = -Inf)
end

PlantSimEngine.dep(::Msg3LvlScaleEchelle2Model) = (Msg3Lvl_echelle3=AbstractMsg3Lvl_Echelle3Model => ("E3",),)
function PlantSimEngine.run!(::Msg3LvlScaleEchelle2Model, models, status, meteo, constants=nothing, extra_args=nothing)
    status_E3 = extra_args.statuses["E3"][1]
    run!(extra_args.models["E3"].Msg3Lvl_echelle3, models, status_E3, meteo, constants)
    status.e2 = status.e3
    status.e3 = status.e3 * 2.0
    status.f2 = status.e3 * 2.0 + status.f3 + status.c
end

#################

struct Msg3LvlScaleEchelle1Model <: AbstractMsg3Lvl_Echelle1Model
end

function PlantSimEngine.inputs_(::Msg3LvlScaleEchelle1Model)
    (b = -Inf, e2 = -Inf, f2 = -Inf)
end

function PlantSimEngine.outputs_(::Msg3LvlScaleEchelle1Model)
    (e1 = -Inf, f1 = -Inf)#, e3 = -Inf)
end

PlantSimEngine.dep(::Msg3LvlScaleEchelle1Model) = (Msg3Lvl_echelle2=AbstractMsg3Lvl_Echelle2Model => ("E2",),)
function PlantSimEngine.run!(::Msg3LvlScaleEchelle1Model, models, status, meteo, constants=nothing, extra_args=nothing)
    
    status_E2 = extra_args.statuses["E2"][1]
    run!(extra_args.models["E2"].Msg3Lvl_echelle2, models, status_E2, meteo, constants, extra_args)
    status.e1 = status.e2
    status.e2 = status.e2 * 2.0
    status.f1 = status.e2 * 2.0 + status.f2 + status.b
    #status.e3 = status.e3 * 7.0
end

#################

struct Msg3LvlScaleAval2Model <: AbstractMsg3Lvl_Aval2Model
end

function PlantSimEngine.inputs_(::Msg3LvlScaleAval2Model)
    (i2 = -Inf,) 
end
    
function PlantSimEngine.outputs_(::Msg3LvlScaleAval2Model)
    (g2 = -Inf,)
end

function PlantSimEngine.run!(::Msg3LvlScaleAval2Model, models, status, meteo, constants=nothing, extra_args=nothing)
    status.g2 = status.i2
end

#################

struct Msg3LvlScaleAvalModel <: AbstractMsg3Lvl_AvalModel
end

function PlantSimEngine.inputs_(::Msg3LvlScaleAvalModel)
    (e1 = -Inf, f1 = -Inf, b2 = - Inf, g2 = -Inf, e3 = -Inf)
end
    
function PlantSimEngine.outputs_(::Msg3LvlScaleAvalModel)
    (g = -Inf,)
end

PlantSimEngine.dep(::Msg3LvlScaleAvalModel) = (Msg3Lvl_aval2=AbstractMsg3Lvl_Aval2Model => ("E2",),)

function PlantSimEngine.run!(::Msg3LvlScaleAvalModel, models, status, meteo, constants=nothing, extra_args=nothing)
    
    status_E2 = extra_args.statuses["E2"][1]
    run!(extra_args.models["E2"].Msg3Lvl_aval2, models, status_E2, meteo, constants, extra_args)
    status.g = status.f1 + status.b2 + status_E2.g2
    status.e3 = status.e3 + 1.0
end

#####################################################################################
# actual testset

@testset "Multiscale nested hard dependencies" begin

    mapping3Lvl = Dict("E1" => (
            Msg3LvlScaleAmontModel(),
            MultiScaleModel(
                model=Msg3LvlScaleAvalModel(),
                mapping=[:e3 => "E3" => :e3, :b2 => "E2" => :b2, :g2 => "E2" => :g2],
            ), 
            MultiScaleModel(
                model=Msg3LvlScaleEchelle1Model(),
                mapping=[:e2 => "E2" => :e2, :f2 => "E2" => :f2,],
            ), Status(a=1.0,)# y = 1.0, z = 1.0)
        ), 
        "E2" => (
            Msg3LvlScaleAmont2Model(),
            Msg3LvlScaleAval2Model(),
            MultiScaleModel(
                model=Msg3LvlScaleEchelle2Model(),
                mapping=[:c => "E1" => :c, :e3 => "E3" => :e3, :f3 => "E3" => :f3,],
            ),
            Status(a2=1.0, i2=1.0,)
        ), 
        "E3" => (
            MultiScaleModel(
                model=Msg3LvlScaleEchelle3Model(),
                mapping=[:c => "E1" => :c,],
            ),
        ),
    )

    outs3Lvl = Dict(
        "E1" => (:g, :e1, :f1),
        "E2" => (:e2, :f2,),
        "E3" => (:e3,)
    )

    meteo3Lvl = Weather([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
        Atmosphere(T=18.0, Wind=1.0, Rh=0.65, Ri_PAR_f=100.0),
        Atmosphere(T=19.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
        Atmosphere(T=30.0, Wind=0.5, Rh=0.6, Ri_PAR_f=100.0),
        Atmosphere(T=20.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
        Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
        Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)])

    mtg3Lvl = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "E1", 0, 0),)
    Node(mtg3Lvl, MultiScaleTreeGraph.NodeMTG("/", "E2", 0, 1))
    Node(mtg3Lvl, MultiScaleTreeGraph.NodeMTG("/", "E3", 0, 2))

    sim3Lvl = @test_nowarn PlantSimEngine.run!(mtg3Lvl, mapping3Lvl, meteo3Lvl, outputs=outs3Lvl, executor=SequentialEx())

    @test length(sim3Lvl.dependency_graph.roots) == 2

    model_amont1 = last(collect(sim3Lvl.dependency_graph.roots)[2])

    model_ech1 = model_amont1.children[1]

    @test model_ech1.hard_dependency[1].children[1].parent.parent == model_ech1

end

#################################################################################################################################################################################

#######################################################################################################################
## Hard dep at another scale, soft dep on the nested model (both at same scale)
#######################################################################################################################

PlantSimEngine.@process "hard_dep_same_scale_echelle1" verbose = false 
PlantSimEngine.@process "hard_dep_same_scale_echelle1bis" verbose = false 
PlantSimEngine.@process "hard_dep_same_scale_echelle3" verbose = false 
PlantSimEngine.@process "hard_dep_same_scale_aval" verbose = false 

#################

struct HardDepSameScaleEchelle3Model <: AbstractHard_Dep_Same_Scale_Echelle3Model
end

function PlantSimEngine.inputs_(::HardDepSameScaleEchelle3Model)
    #(b = -Inf, 
    (d = -Inf,)
end

function PlantSimEngine.outputs_(::HardDepSameScaleEchelle3Model)
    (e3 = -Inf, f3 = -Inf)
end

function PlantSimEngine.run!(::HardDepSameScaleEchelle3Model, models, status, meteo, constants=nothing, extra_args=nothing)
    status.e3 = 1.0#status.c
    status.f3 = 1.0
end

#################

struct HardDepSameScaleEchelle1Model <: AbstractHard_Dep_Same_Scale_Echelle1Model
end

function PlantSimEngine.inputs_(::HardDepSameScaleEchelle1Model)
    (a = -Inf, e2 = -Inf)# e3 = -Inf, f3 = -Inf)
end

function PlantSimEngine.outputs_(::HardDepSameScaleEchelle1Model)
    (e1 = -Inf, f1 = -Inf)
end

#PlantSimEngine.dep(::HardDepSameScaleEchelle1Model) = (hard_dep_same_scale_echelle3=AbstractHard_Dep_Same_Scale_Echelle3Model => ("E3",),)

# exta_args = sim_object
function PlantSimEngine.run!(::HardDepSameScaleEchelle1Model, models, status, meteo, constants=nothing, sim_object=nothing)
    #run!(sim_object.models["E3"].hard_dep_same_scale_echelle3, models, status, meteo, constants)
    status.e1 = 1.0#status.e3
    #status.e3 = status.e3 * 2.0
    status.f1 = status.a #status.e3 * 2.0 + status.f3 + status.a
    #status.c = 1.0 + status.e2
end

#################

struct HardDepSameScaleEchelle1bisModel <: AbstractHard_Dep_Same_Scale_Echelle1BisModel
end

function PlantSimEngine.inputs_(::HardDepSameScaleEchelle1bisModel)
    (e3 = -Inf,)
end

function PlantSimEngine.outputs_(::HardDepSameScaleEchelle1bisModel)
    (e2 = -Inf, f2 = -Inf)
end

PlantSimEngine.dep(::HardDepSameScaleEchelle1bisModel) = (hard_dep_same_scale_echelle3=AbstractHard_Dep_Same_Scale_Echelle3Model => ("E3",),)

# exta_args = sim_object
function PlantSimEngine.run!(::HardDepSameScaleEchelle1bisModel, models, status, meteo, constants=nothing, sim_object=nothing)
    status_E3 = sim_object.statuses["E3"][1]
    run!(sim_object.models["E3"].hard_dep_same_scale_echelle3, models, status_E3, meteo, constants)
    status.e2 = status_E3.e3
    status_E3.e3 = status_E3.e3 * 2.0
    status.f2 = status_E3.e3 * 2.0
end

#################

struct HardDepSameScaleAvalModel <: AbstractHard_Dep_Same_Scale_AvalModel
end

function PlantSimEngine.inputs_(::HardDepSameScaleAvalModel)
    (e3 = -Inf,) # f1 or f2 ? 
end
    
function PlantSimEngine.outputs_(::HardDepSameScaleAvalModel)
    (g = -Inf,)
end

function PlantSimEngine.run!(::HardDepSameScaleAvalModel, models, status, meteo, constants=nothing, extra_args=nothing)
    status.g = status.e3
    #status.h = status.e1
end

####################################################################
# actual testset

@testset "Soft dependency whose parent is a hard dependency of a parent at a different scale" begin
    mapping = Dict(
        "E1" => (HardDepSameScaleEchelle1Model(),
            MultiScaleModel(
                model=HardDepSameScaleEchelle1bisModel(),
                mapping=[:e3 => "E3" => :e3],
            ),
            Status(a=1.0),), 
        "E3" => (
            HardDepSameScaleEchelle3Model(),
            HardDepSameScaleAvalModel(), Status(d=1.0,),
        ),
    )

    outs = Dict(
        "E1" => (:e1, :f1, :e2, :f2),
        "E3" => (:e3,)
    )

    meteo = Weather([
        Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
        Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)])

    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "E1", 0, 0),)
    Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "E3", 0, 1))

    sim = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, outputs=outs, executor = SequentialEx())

    model_1 = last(collect(sim.dependency_graph.roots)[1])
    
    # Downscale soft dependency aval should point to the root node 1bis, instead of the 'real parent' 3, which is an inner hard dependency to 1bis
    # so 1 and aval both point to 1bis
    @test length(model_1.children) == 2
end


#################################################################################################################################################################################

#######################################################################################################################
## 2 different scales that make use of the *same* model
#######################################################################################################################

PlantSimEngine.@process "single_model_multiple_scales" verbose = false 

struct SingleModelScale1 <: AbstractSingle_Model_Multiple_ScalesModel
end
struct SingleModelScale2 <: AbstractSingle_Model_Multiple_ScalesModel
end
struct SingleModelScale2bis <: AbstractSingle_Model_Multiple_ScalesModel
end
struct SingleModelScale3 <: AbstractSingle_Model_Multiple_ScalesModel
end

function PlantSimEngine.inputs_(::SingleModelScale1)
    (in = -Inf, in1 = -Inf)
end
function PlantSimEngine.outputs_(::SingleModelScale1)
    (out = -Inf, out1 = -Inf)
end

function PlantSimEngine.inputs_(::SingleModelScale2)
    (in = -Inf, in2 = -Inf)
end
function PlantSimEngine.outputs_(::SingleModelScale2)
    (out = -Inf, out2 = -Inf)
end

function PlantSimEngine.inputs_(::SingleModelScale2bis)
    (in = -Inf, in2bis = -Inf)
end
function PlantSimEngine.outputs_(::SingleModelScale2bis)
    (out = -Inf, out2bis = -Inf)
end

function PlantSimEngine.inputs_(::SingleModelScale3)
    (in = -Inf, in3 = -Inf, out2 = -Inf, out1 = -Inf)
end
function PlantSimEngine.outputs_(::SingleModelScale3)
    (out = -Inf, out3 = -Inf)
end

PlantSimEngine.dep(::SingleModelScale1) = (single_model_multiple_scales=AbstractSingle_Model_Multiple_ScalesModel => ("E2bis", "E2"),)

# extra_args = sim_object
function PlantSimEngine.run!(::SingleModelScale1, models, status, meteo, constants=nothing, sim_object=nothing)
    status_E2 = sim_object.statuses["E2"][1]
    status_E2b = sim_object.statuses["E2bis"][1]
    run!(sim_object.models["E2"].single_model_multiple_scales, models, status_E2, meteo, constants)
    run!(sim_object.models["E2bis"].single_model_multiple_scales, models, status_E2b, meteo, constants)
    status.out = status_E2.out+ status_E2b.out + status.in
    status.out1 = status_E2.out2 + status_E2b.out2bis + status.out1
end

function PlantSimEngine.run!(::SingleModelScale2, models, status, meteo, constants=nothing, sim_object=nothing)
    status.out = status.in + 1.0
    status.out2 = status.in2
end

function PlantSimEngine.run!(::SingleModelScale2bis, models, status, meteo, constants=nothing, sim_object=nothing)
    status.out = status.in + 2.0
    status.out2bis = status.in2bis
end

function PlantSimEngine.run!(::SingleModelScale3, models, status, meteo, constants=nothing, sim_object=nothing)
    status.out = status.in + status.in3 + status.out2;
    status.out3 = status.in3 + status.out1
end

#############################
## Actual testset

@testset "Process/model reuse at different scales" begin

    mapping = Dict(
      "E1" => (
      SingleModelScale1(),
      Status(in = 1.0, in1 = 1.0),
      ),
      "E2" => (
      SingleModelScale2(),
      Status(in = 1.0, in2 = 1.0),
      ),
      "E2bis" => (
      SingleModelScale2bis(),
      Status(in = 1.0, in2bis = 1.0),
      ),
      "E3" => (
          MultiScaleModel(
          model =  SingleModelScale3(),
          mapping = [:out1 => "E1" => :out1, :out2 => "E2" => :out2, ],
      ),
      Status(in= 1.0, in3 = 1.0,),
      ),
    )
  
  outs = Dict(
      "E1" => (:out, :out1),
      "E2" => (:out, :out2),
      "E2bis" => (:out,), # comment this line out, and remove nodes relating to E2 and E2bis to expose the issue in #103
      "E3" => (:out3,)
      )
  
  meteo = Weather([
          Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
          Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)
      
  ])
  
  mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "E1", 0, 0),)
  Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "E3", 0, 1))
  Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "E2", 0, 2))
  Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "E2bis", 0, 3))
  
  sim = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, outputs = outs, executor = SequentialEx())
  
  roots = sim.dependency_graph.roots
  @test length(sim.dependency_graph.roots) == 1

  model_1 = last(collect(roots)[1])

  @test length(model_1.children) == 1
  @test length(model_1.hard_dependency) == 2
  @test model_1.children[1].parent[1] == model_1
  @test model_1.hard_dependency[1].parent == model_1
  @test model_1.hard_dependency[2].parent == model_1

  end



##########################
## No outputs when simulating a mapping with one meteo timestep #105
##########################

@testset "Issue 105 : no outputs when simulating a mapping with one meteo timestep" begin

    using PlantSimEngine, PlantMeteo, DataFrames
    using PlantSimEngine.Examples
    mtg = import_mtg_example()
    m = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Status(var1=10.0, var2=1.0,)
        )
    )
    vars = Dict{String,Any}("Leaf" => (:var1,))
    out = run!(mtg, m, Atmosphere(T=20.0, Wind=1.0, Rh=0.65), outputs=vars, executor=SequentialEx())
    df = outputs(out, DataFrame)
    @test DataFrames.nrow(df) == 2
end

##########################
## Multiscale : outputs not saved when dependency graph only has one depth level #111
##########################

# Probably very similar to #105
@testset "Issue 111 : Multiscale : outputs not saved when dependency graph only has one depth level" begin

    using Pkg
    Pkg.develop("PlantSimEngine")
    using PlantSimEngine
    using PlantSimEngine.Examples
    using MultiScaleTreeGraph

    status2 = (var1=15.0, var2=0.3)

    meteo = Weather([
        Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
        Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)])

    outs = Dict("Default" => (:var1,))
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 0, 0),)

    mapping = Dict(
        "Default" => (
            Process1Model(1.0),
            Status(var1=15.0, var2=0.3,),
        ),
    )

    sim = run!(mtg, mapping, meteo; outputs=outs)
    using DataFrames
    df = outputs(sim, DataFrame)
    @test DataFrames.nrow(df) == PlantSimEngine.get_nsteps(meteo)

end


############################################
### #86 : BoundsError with a single model and several Weather timesteps
############################################

using PlantSimEngine
PlantSimEngine.@process "toy" verbose = false

"""
Inputs : a, b, c
Outputs : d, e
"""

struct ToyToyModel{T} <: AbstractToyModel 
    internal_constant::T
end

function PlantSimEngine.inputs_(::ToyToyModel)
    (a = -Inf, b = -Inf, c = -Inf)
end

# note : here, d is set with = further down, but e is set with +=, ie inf + thingy, is this a bug on my end ?
function PlantSimEngine.outputs_(::ToyToyModel)
    (d = -Inf, e = -Inf)
end

function PlantSimEngine.run!(m::ToyToyModel, models, status, meteo, constants=nothing, extra_args=nothing)
    status.d = m.internal_constant * status.a 
    status.e += m.internal_constant
end


meteo = Weather([    
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
        Atmosphere(T=18.0, Wind=1.0, Rh=0.65, Ri_PAR_f=100.0),
])

model = ModelList(
    ToyToyModel(1),
   status = ( a = 1, b = 0, c = 0),
    #nsteps = length(meteo)
)
sim = run!(model, meteo)