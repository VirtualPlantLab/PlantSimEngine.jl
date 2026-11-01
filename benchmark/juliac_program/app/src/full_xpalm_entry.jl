# Included inside PSEProgramApp after ReusableProgram and FullXPalmFixture.
# Only module/build-time authoring loads Palm parameters or constructs ModelSpec.
const FULL_SETUP = FullXPalmFixture.authoring()
const FULL_REPRODUCTIVE_SETUP = FullXPalmFixture.authoring(; reproductive=true)
const FULL_PROGRAM = ReusableProgram.prepare(FULL_SETUP.applications;
    initial=FULL_SETUP.initial.templates)

_full_runtime_model(model, rate::Float64) = model
function _full_runtime_model(model::FullXPalmFixture.XPalm.Models.PhyllochronModel, rate::Float64)
    return FullXPalmFixture.XPalm.Models.PhyllochronModel(model.age_palm_maturity, rate, rate)
end

function _full_native_tree(descriptor)
    isempty(descriptor) && throw(ArgumentError("empty full-XPalm topology"))
    entry = first(descriptor)
    isnothing(entry.parent) || throw(ArgumentError("topology must begin with its root"))
    encoding = FullXPalmFixture.MTG.NodeMTG(entry.link, entry.scale, entry.index, entry.level)
    attrs = NamedTuple()
    N = FullXPalmFixture.MTG.Node{typeof(encoding),typeof(attrs)}
    root = N(entry.id, nothing, N[], encoding, attrs, nothing)
    nodes = Dict{Int,N}(entry.id => root)
    for i in 2:length(descriptor)
        row = descriptor[i]
        haskey(nodes, row.id) && throw(ArgumentError("duplicate full-XPalm topology ID"))
        isnothing(row.parent) && throw(ArgumentError("multiple full-XPalm topology roots"))
        haskey(nodes, row.parent) || throw(ArgumentError("topology must be parent-first"))
        node = N(row.id, nothing, N[],
            FullXPalmFixture.MTG.NodeMTG(row.link, row.scale, row.index, row.level), attrs, nothing)
        FullXPalmFixture.MTG.addchild!(nodes[row.parent], node)
        nodes[row.id] = node
    end
    return root
end

"""
    simulate_full_xpalm(days::Int, rate::Float64, reproductive::Bool; retain=true)

Instantiate and run the complete original architecture=false XPalm graph from
one build-time program. Duration and phyllochron rates remain data. The optional
reproductive parameter set changes original phenology parameters; scientific
kernels, RNG methods and application contracts remain the original XPalm ones.
No Palm construction, parameter loading or scenario compilation occurs here.
"""
function simulate_full_xpalm(days::Int, rate::Float64, reproductive::Bool; retain=true)
    days >= 0 || throw(ArgumentError("negative full-XPalm duration"))
    isfinite(rate) && rate >= 0 || throw(ArgumentError("invalid full-XPalm phyllochron rate"))
    setup = reproductive ? FULL_REPRODUCTIVE_SETUP : FULL_SETUP
    models = ReusableProgram._schema_map(model -> _full_runtime_model(model, rate), setup.models)
    state = ReusableProgram.instantiate(FULL_PROGRAM, models, _full_native_tree(setup.topology);
        initial=setup.initial.templates, objects=setup.initial.objects, retain)
    constants = FullXPalmFixture.PSE.Constants()
    for environment in FullXPalmFixture.rows(days)
        ReusableProgram.step!(state, environment; constants)
    end
    return state
end

# Deliberately no Any/show fallback. Each admitted scalar or array element is
# printed through a concrete method; adding a new payload family requires an
# explicit encoding. Arrays use [value;value], including nested arrays.
_full_print_value(value::Bool) = print(Core.stdout, value ? "true" : "false")
_full_print_value(value::Integer) = print(Core.stdout, value)
_full_print_value(value::AbstractFloat) = print(Core.stdout, value)
_full_print_value(value::Symbol) = print(Core.stdout, value)
_full_print_value(value::AbstractString) = print(Core.stdout, value)
_full_print_value(value::FullXPalmFixture.PSE.ObjectId) = _full_print_value(value.value)
_full_print_value(::Nothing) = print(Core.stdout, "null")
_full_print_value(::Missing) = print(Core.stdout, "missing")
_full_print_value(reference::Base.RefValue) = _full_print_value(reference[])
function _full_print_value(value::AbstractArray)
    print(Core.stdout, '[')
    first_element = true
    for element in value
        first_element || print(Core.stdout, ';')
        _full_print_value(element)
        first_element = false
    end
    print(Core.stdout, ']')
    return nothing
end

_full_print_record(::Tuple{})=println(Core.stdout)
function _full_print_record(fields::Tuple)
    _full_print_value(first(fields))
    remaining=ReusableProgram._schema_tail(fields)
    isempty(remaining) || print(Core.stdout,',')
    _full_print_record(remaining)
    return nothing
end

_full_print_status_fields(category, id, parent, link, index, ::Tuple{}, ::Tuple{}) = nothing
function _full_print_status_fields(category, id, parent, link, index, names::Tuple, payloads::Tuple)
    _full_print_record(("S",category,id,parent,link,index,first(names),first(payloads)))
    _full_print_status_fields(category, id, parent, link, index, ReusableProgram._schema_tail(names), ReusableProgram._schema_tail(payloads))
    return nothing
end
_full_print_cohorts(::Tuple{}) = nothing
function _full_print_cohorts(cohorts::Tuple)
    cohort = first(cohorts)
    category = ReusableProgram._cohort_key(cohort)
    for row in sortperm(cohort.ids)
        node = cohort.nodes[row]
        parent = FullXPalmFixture.MTG.parent(node)
        parent_id = isnothing(parent) ? 0 : FullXPalmFixture.MTG.node_id(parent)
        _full_print_record(("T",category,cohort.ids[row],parent_id,
            FullXPalmFixture.MTG.link(node),FullXPalmFixture.MTG.index(node)))
        status = cohort.rows[row]
        _full_print_status_fields(category, cohort.ids[row], parent_id,
            FullXPalmFixture.MTG.link(node), FullXPalmFixture.MTG.index(node),
            keys(status), FullXPalmFixture.PSE.refvalues(status))
    end
    _full_print_cohorts(ReusableProgram._schema_tail(cohorts))
    return nothing
end

_full_print_streams(application, ::Tuple{}, ::Tuple{}) = nothing
function _full_print_streams(application, names::Tuple, histories::Tuple)
    variable = first(names)
    for sample in first(histories).retained
        _full_print_record(("O",application,sample.object_id,sample.step,variable,sample.value))
    end
    _full_print_streams(application, ReusableProgram._schema_tail(names), ReusableProgram._schema_tail(histories))
    return nothing
end

_full_print_rng_field(::Val{false}, model, field, application) = nothing
function _full_print_rng_field(::Val{true}, model, ::Val{FIELD}, application) where {FIELD}
    # Four scalar UInt64 draws from a private copy avoid a heterogeneous
    # fingerprint object and leave the scientific generator unchanged.
    rng = copy(getfield(model, FIELD))
    print(Core.stdout, "R,", application, ',', FIELD, ",[")
    for i in 1:4
        i == 1 || print(Core.stdout, ';')
        _full_print_value(FullXPalmFixture.XPalm.Random.rand(rng, UInt64))
    end
    println(Core.stdout, ']')
    return nothing
end
function _full_print_model_rngs(model::M, application) where {M}
    # These Val arguments derive only from the known model type and literal
    # field names, never from IDs, counts, parameter values or runtime Symbols.
    _full_print_rng_field(Val(hasfield(M, :rng)), model, Val(:rng), application)
    _full_print_rng_field(Val(hasfield(M, :random_generator)), model, Val(:random_generator), application)
    return nothing
end
_full_print_applications(::Tuple{}) = nothing
function _full_print_applications(applications::Tuple)
    application = first(applications)
    _full_print_streams(application.recipe.name, keys(application.streams), values(application.streams))
    _full_print_model_rngs(application.model, application.recipe.name)
    _full_print_applications(ReusableProgram._schema_tail(applications))
    return nothing
end

"""
Print the full native result without generic value display:
F,objects,step,applications
T,category,id,parent,link,index
S,category,id,parent,link,index,variable,encodedvalue
O,application,id,step,variable,encodedvalue
R,application,field,[nextUInt64;nextUInt64;nextUInt64;nextUInt64]

Root parent is 0; ObjectId values print as their numeric IDs. Symbols print
without a colon, Booleans as true/false, and arrays in semicolon brackets.
Topology rows cover every object, including empty status schemas. Topology and
status rows follow cohort order then ascending object IDs. Output rows follow
original application/output declaration order and retained sample order.
"""
function _print_full_xpalm(state)
    _full_print_record(("F",length(state.nodes),state.step,length(state.applications)))
    _full_print_cohorts(state.cohorts)
    _full_print_applications(state.applications)
    return nothing
end
