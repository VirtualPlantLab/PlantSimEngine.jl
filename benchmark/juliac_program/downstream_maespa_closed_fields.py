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
    raise ValueError("not an owned closed-field source: "+relative)
