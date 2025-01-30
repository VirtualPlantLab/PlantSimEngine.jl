# Tests:
# Defining a list of models without status:
#=
@testset "ModelList with no status" begin
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model()
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))
    @test !is_initialized(leaf)
    @test to_initialize(leaf) == (process1=(:var1, :var2), process2=(:var1,))
    @test length(status(leaf)) == 1

    # Requiring 3 steps for initialization:
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        nsteps=3
    )

    @test length(status(leaf)) == 3
    @test status(leaf, :var1) == [-Inf, -Inf, -Inf]
end;


@testset "process" begin
    @test PlantSimEngine.process(Process1Model(1.0)) == :process1
    @test PlantSimEngine.process(:process1 => Process1Model(1.0)) == :process1

    models =
        (
            Process1Model(1.0),
            Process2Model()
        )

    @test [(process(i), i) for i in models] == Tuple{Symbol,AbstractModel}[(:process1, Process1Model(1.0)), (:process2, Process2Model())]

    models_named = (
        process1=Process1Model(1.0),
        process2=Process2Model()
    )

    @test [(process(i), i) for i in models_named] == [(process(i), i) for i in models]
end

@testset "ModelList with no process names" begin
    with_names = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model()
    )

    without_names = ModelList(
        Process1Model(1.0),
        Process2Model()
    )

    @test with_names.models == without_names.models
    @test with_names.status.var1 == without_names.status.var1
    @test with_names.status.var2 == without_names.status.var2
end;

@testset "ModelList with a partially initialized status" begin
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=(var1=15.0,)
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))
    st.var1 = 15.0
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))
    @test !is_initialized(leaf)
    @test to_initialize(leaf) == (process1=(:var2,),)

    # Requiring 3 steps for initialization:
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=(var1=15.0,),
        nsteps=3
    )

    @test length(status(leaf)) == 3
    @test status(leaf, :var1) == [15.0, 15.0, 15.0]
end;

@testset "ModelList with fully initialized status" begin
    vals = (var1=15.0, var2=0.3)
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=vals
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))

    for i in keys(vals)
        setproperty!(st, i, getproperty(vals, i))
    end
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))

    @test is_initialized(leaf)
    @test to_initialize(leaf) == NamedTuple()
end;


@testset "ModelList with independant models (and missing one in the middle)" begin
    vals = (var1=15.0, var2=0.3)
    leaf = ModelList(
        process1=Process1Model(1.0),
        process3=Process3Model(),
        status=vals
    )

    @test to_initialize(leaf) == (process3=(:var5,),)

    # NB: decompose this test because the order of the variables change with the Julia version
    inits = init_variables(leaf)
    sorted_vars = sort([keys(inits.process3)...])

    @test [getfield(inits.process3, i) for i in sorted_vars] ==
          fill(-Inf, 3)
end;

@testset "Copy a ModelList" begin
    vars = (var1=15.0, var2=0.3)
    # Create a model list:
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=vars
    )

    # Copy the model list:
    ml2 = copy(models)

    @test DataFrame(status(ml2)) == DataFrame(status(models))

    # Copy the model list with new status:
    tst = TimeStepTable([Status(var1=20.0, var2=0.5)])
    ml3 = copy(models, tst)

    @test status(ml3) == tst
    @test ml3.models == models.models


    cp_models = copy([models, ml3])
    @test cp_models == [models, ml3]

    cp_models = copy(Dict("models" => models, "ml3" => ml3))
    @test cp_models == Dict("models" => models, "ml3" => ml3)
end;

@testset "Convert ModelList status variables into new types" begin
    ref_vars = init_variables(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
    )
    type_promotion = Dict(Real => Float32)

    process3_Float32 = PlantSimEngine.convert_vars(ref_vars.process3, type_promotion)

    @test all([isa(getfield(process3_Float32, i), Float32) for i in keys(process3_Float32)])

    process3_same = PlantSimEngine.convert_vars(ref_vars.process3, nothing)
    @test process3_same == ref_vars.process3
end


@testset "ModelList dependencies" begin

    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        process4=Process4Model(),
        process5=Process5Model(),
        process6=Process6Model(),
        # process7=Process7Model(),
        # status=(var1=15.0, var2=0.3)
    )

    deps = dep(models).roots

    @test collect(keys(deps)) == [:process4]

    @test deps[:process4].value == Process4Model()
    @test isa(deps[:process4], PlantSimEngine.SoftDependencyNode)

    process3 = deps[:process4].children[1]
    @test process3.value == Process3Model()
    @test isa(process3, PlantSimEngine.SoftDependencyNode)

    @test process3.hard_dependency[1].value == Process2Model()
    @test isa(process3.hard_dependency[1], PlantSimEngine.HardDependencyNode)

    @test process3.hard_dependency[1].children[1].value == Process1Model(1.0)
    @test isa(process3.hard_dependency[1].children[1], PlantSimEngine.HardDependencyNode)

    @test process3.children[1].value == Process5Model()
    @test isa(process3.children[1], PlantSimEngine.SoftDependencyNode)
end
=#



# very naive function, doesn't generate full partition sets
# insert_errors : could duplicate a value, add a nonexistent one, make one the wrong type ?
#=function generate_output_tuple(vars_tuple, insert_errors, count)

    outputs_tuples_vector = [NamedTuple()]

    # number not exact, but trying every permutation sounds like a waste of time
    for i in 1:max(count, length(vars_tuple))
        new_tuple = ()
        # TODO 
        new_tuple = (new_tuple..., new_var)
    end 
    return outputs_tuples_vector
end=#

function test_filtered_output(m::ModelList, status_tuple, requested_outputs, meteo)

    nsteps = isa(meteo, DataFrame) ? nrow(meteo) : length(meteo)
    preallocated_outputs = PlantSimEngine.pre_allocate_outputs(m, requested_outputs, nsteps)
    @test length(preallocated_outputs) == nsteps
    if length(requested_outputs) > 0
        @test length(preallocated_outputs[1]) == length(requested_outputs)
    else            
        # don't compare with the status because unnecessary variables in the status are discarded in the filtered outputs
        out_vars_all = merge(init_variables(m; verbose=false)...)
        println(out_vars_all)
        @test length(preallocated_outputs[1]) == length(out_vars_all)
    end
    
    filtered_outputs_modellist = run!(m, meteo; outputs=requested_outputs, executor = SequentialEx())

    # compare filtered output of a modellist with the filtered output of the equivalent simulation in multiscale mode
    mtg, mapping, outputs_mapping = PlantSimEngine.modellist_to_mapping(m, status_tuple; nsteps=nsteps, outputs=requested_outputs)
    graphsim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=outputs_mapping)
 
    sim2 = run!(graphsim,
         meteo,
         PlantMeteo.Constants(),
         nothing;
         check=true,
         executor=SequentialEx()
     )
    return compare_outputs_modellist_mapping(filtered_outputs_modellist, graphsim)
end

# TODO restrict status to a single Status
#@testset "ModelList outputs preallocation" begin
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    vals = (var1=15.0, var2=0.3, TT_cu=cumsum(meteo_day.TT))
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=vals
    )
    outs=(:var3,)

    @test test_filtered_output(leaf, vals, outs, meteo_day)
    
    meteos = get_simple_meteo_bank()
    modellists, status_tuples, outs_vectors = get_modellist_bank()

    for i in 1:length(modellists)

        modellist = modellists[i]
        status_tuple = status_tuples[i]
        outs_vector = outs_vectors[i]
        all_vars = init_variables(modellist)

        #insert_errors = true
        #outs_vector = generate_output_tuple(all_vars, insert_errors)

        for meteo in meteos
            for out_tuple in outs_vector
                println(out_tuple)
                @test test_filtered_output(modellist, status_tuple, out_tuple, meteo)
            end
        end
    end
    
    @enter test_filtered_output(modellists[2], status_tuples[2], outs_vectors[2][2], meteos[1])
#end