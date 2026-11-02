"""Inference-only literal-field transforms for the frozen MAESPA variant.

No MAESPA files are written here. The central typing recipe calls repair() and
owns regeneration, the full patch, and the combined manifest. Each finite
Symbol loop is expanded in original order. let-local values avoid captured
loop boxes; scientific expressions, validation predicates and errors remain.
"""
import re

REPAIRED=(
    "src/processes/soil_water_balance.jl",
    "src/processes/daily_whole_plant_respiration_scene_aggregation.jl",
    "src/processes/radiation/crown_radiation.jl",
    "src/processes/canopy_air_microclimate.jl",
    "src/processes/non_tuzet_crown_leaf_exchange_controller.jl",
    "src/processes/logical_leaf_unit_layout.jl",
    "src/processes/civil_day_respiration_accumulator.jl",
    "src/processes/meteorology_scenarios.jl",
    "src/processes/meteorology.jl",
    "src/processes/solar_geometry.jl",
    "src/processes/coupled_leaf_energy_balance.jl",
    "src/processes/canopy_air_trial_evaluation.jl",
    "src/processes/crown_leaf_respiration_accounting.jl",
)

def unroll_named_loops(text, constants=True):
    # Each selected loop has no nested block with an end at this indentation.
    pattern=re.compile(r'(?m)^(?P<i> +)for name in (?P<seq>\([^)]*\)|_DAILY_WHOLE_PLANT_RESPIRATION_SCENE_[A-Z_]+)\n(?P<body>.*?)(?P=i)end\n',re.S)
    count=0
    def replace(m):
        nonlocal count
        seq=m['seq']
        if seq.startswith('_DAILY_'):
            declaration=re.search(r'const '+re.escape(seq)+r' = \((.*?)\n\)',text,re.S)
            assert declaration,seq
            seq=declaration[1]
        names=re.findall(r':([A-Za-z_][A-Za-z_0-9]*)',seq)
        assert names and not re.search(r'\b(?:for|while|if|begin|let)\b',m['body']),m[0]
        count+=1
        result=[]
        for name in names:
            # The scientific/validation expressions and error rendering remain
            # byte-for-byte, apart from making the property key a literal.
            body=re.sub(r'(getproperty\(status,\s*|setproperty!\(status,\s*)name(?=[,)])',lambda x:x[1]+':'+name,m['body'])
            result.append(m['i']+'let name = :'+name+'\n'+body+m['i']+'end\n')
        return ''.join(result)
    return pattern.sub(replace,text),count


def _replace_once(text,old,new):
    assert text.count(old)==1,old[:100]
    return text.replace(old,new,1)

def _schema_names(source,sequence):
    if sequence.startswith("("):
        content=sequence
    elif sequence=="_NON_TUZET_CROWN_STATUS_FLOAT_OUTPUTS":
        expected="const _NON_TUZET_CROWN_STATUS_FLOAT_OUTPUTS = filter(\n    name -> !(name in _NON_TUZET_CROWN_INTERNAL_DIAGNOSTICS), _NON_TUZET_CROWN_FLOAT_VECTOR_OUTPUTS)"
        assert source.count(expected)==1
        excluded=_schema_names(source,"_NON_TUZET_CROWN_INTERNAL_DIAGNOSTICS")
        return [name for name in _schema_names(source,"_NON_TUZET_CROWN_FLOAT_VECTOR_OUTPUTS") if name not in excluded]
    else:
        declaration=re.search(r"(?:const )?"+re.escape(sequence)+r" = \((.*?)\n *\)",source,re.S)
        assert declaration,sequence
        content=declaration[1]
    names=re.findall(r":([A-Za-z_][A-Za-z_0-9]*)",content)
    assert names,sequence
    return names

def _unroll_schema_loops(source):
    pattern=re.compile(r"(?m)^(?P<i> +)for name in (?P<seq>\([^)]*\)|_[A-Z_]+|output_names)\n(?P<body>.*?)(?P=i)end\n",re.S)
    count=0
    def expand(match):
        nonlocal count
        count+=1
        body=match["body"]
        assert not re.search(r"\b(?:for|while|if|begin|let|break)\b",body),body[:120]
        # One original scalar-input validation loop skips atmosphere fields.
        # Preserve that predicate/evaluation and skip only its remaining body.
        if "continue" in body:
            first,rest=body.split("\n",1)
            assert first.strip()=="name in _MAESPA_CANOPY_ATMOSPHERE_AIR_FIELDS && continue"
            assert "continue" not in rest
            body=match['i']+"    if !(name in _MAESPA_CANOPY_ATMOSPHERE_AIR_FIELDS)\n"+rest+match['i']+"    end\n"
        iterations=[]
        for name in _schema_names(source,match['seq']):
            literal=re.sub(r"((?:getproperty|getfield|setproperty!)\((?:status|result),\s*)name(?=[,)])",lambda item:item[1]+":"+name,body)
            iterations.append(match['i']+"let name = :"+name+"\n"+literal+match['i']+"end\n")
        return "".join(iterations)
    return pattern.sub(expand,source),count

def _literal_result_loop(source,helper,iterator="fieldnames(typeof(result))",variable="name",getter="getproperty",namedtuple=False):
    old=f"    for {variable} in {iterator}\n        setproperty!(status, {variable}, {getter}(result, {variable}))\n    end"
    updated=_replace_once(source,old,f"    {helper}(status, result)")
    bound="R<:NamedTuple" if namedtuple else "R"
    method=(f"\n@generated function {helper}(status, result::R) where {{{bound}}}\n"
        f"    assignments = [:(setproperty!(status, $(QuoteNode(name)), {getter}(result, $(QuoteNode(name))))) for name in fieldnames(R)]\n"
        "    return Expr(:block, assignments..., :(return nothing))\nend\n")
    return updated+method


def repair(relative,source):
    if relative==REPAIRED[0]:
        old='function _restore_soil_water_balance_status!(status, snapshot)\n    for name in keys(snapshot)\n        setproperty!(status, name, getproperty(snapshot, name))\n    end\n    return nothing\nend'
        new='@generated function _restore_soil_water_balance_status!(status, snapshot::S) where {S<:NamedTuple}\n    assignments = [:(setproperty!(status, $(QuoteNode(name)), getproperty(snapshot, $(QuoteNode(name))))) for name in fieldnames(S)]\n    return Expr(:block, assignments..., :(return nothing))\nend'
        return _replace_once(source,old,new)
    if relative==REPAIRED[1]:
        result,count=unroll_named_loops(source)
        assert count==12,count
        old='    for name in fieldnames(typeof(result))\n        setproperty!(status, name, getproperty(result, name))\n    end'
        result=_replace_once(result,old,"    _assign_daily_respiration_result!(status, result)")
        marker="function PlantSimEngine.run!(\n    model::MAESPADailyWholePlantRespirationSceneAggregation,"
        assignment='@generated function _assign_daily_respiration_result!(status, result::R) where {R}\n    assignments = [:(setproperty!(status, $(QuoteNode(name)), getproperty(result, $(QuoteNode(name))))) for name in fieldnames(R)]\n    return Expr(:block, assignments..., :(return nothing))\nend\n\n'
        return _replace_once(result,marker,assignment+marker)
    if relative==REPAIRED[2]:
        start=source.index("function _initialize_crown_radiation!")
        end=source.index("\nfunction _crown_diffuse_update_decision",start)
        result,count=unroll_named_loops(source[start:end])
        assert count==6,count
        return source[:start]+result+source[end:]
    if relative==REPAIRED[3]:
        result,count=_unroll_schema_loops(source)
        assert count==2,count
        return _literal_result_loop(result,"_assign_canopy_air_microclimate_fields!",getter="getfield")
    if relative==REPAIRED[4]:
        result,count=_unroll_schema_loops(source)
        assert count==7,count
        return result
    if relative==REPAIRED[5]:
        result,count=_unroll_schema_loops(source)
        assert count==9,count
        return result
    if relative==REPAIRED[6]:
        return _literal_result_loop(source,"_assign_civil_day_accumulator_fields!")
    if relative==REPAIRED[7]:
        return _literal_result_loop(source,"_assign_meteorology_scenario_fields!",iterator="keys(result)",variable="variable",namedtuple=True)
    if relative==REPAIRED[8]:
        return _literal_result_loop(source,"_assign_meteorology_reconstruction_fields!",iterator="keys(result)",variable="variable",namedtuple=True)
    if relative==REPAIRED[9]:
        return _literal_result_loop(source,"_assign_solar_geometry_fields!",iterator="keys(result)",namedtuple=True)
    if relative==REPAIRED[10]:
        old="        for (name, value) in pairs(PlantSimEngine.outputs_(model))\n            setproperty!(status, name, oftype(getproperty(status, name), value))\n        end"
        result=_replace_once(source,old,"        _reset_coupled_leaf_energy_fields!(status, PlantSimEngine.outputs_(model))")
        return result+"\n@generated function _reset_coupled_leaf_energy_fields!(status, defaults::NamedTuple{N}) where {N}\n    assignments = [:(let value = getproperty(defaults, $(QuoteNode(name))); setproperty!(status, $(QuoteNode(name)), oftype(getproperty(status, $(QuoteNode(name))), value)); end) for name in N]\n    return Expr(:block, assignments..., :(return nothing))\nend\n"
    if relative in REPAIRED[11:13]:
        helper=("_throw_canopy_air_trial_evaluation" if relative==REPAIRED[11]
            else "_throw_crown_leaf_respiration_accounting")
        # Both helpers return Bottom for every reason. Force literal-reason
        # propagation at their call sites; avoid compiling unrelated display
        # branches for NamedTuple/Type payloads. Messages/checks stay untouched.
        pattern=r"@noinline(?: Base\.@constprop :aggressive)? function "+re.escape(helper)+r"\("
        result,count=re.subn(pattern,"@inline Base.@constprop :aggressive function "+helper+"(",source)
        assert count==1,(relative,count)
        return result
    raise ValueError("not an owned closed-field source: "+relative)
