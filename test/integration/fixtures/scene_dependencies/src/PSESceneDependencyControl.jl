module PSESceneDependencyControl

import PlantSimEngine as PSE
include("NestedCallControl.jl")

const SCENE = PSE._with_object_id_domain(PSE.CompositeModel(
    PSE.Object(:scene; scale=:Scene, kind=:scene),
    PSE.Object(:crown_1; scale=:Crown, kind=:crown, parent=:scene),
    PSE.Object(:crown_2; scale=:Crown, kind=:crown, parent=:scene),
), PSE.ObjectId{Symbol})
const CROWNS = PSE.Many(PSE.SceneScope(); scale=:Crown, kind=:crown,
    id=(:crown_1, :crown_2), process=:crown_process)
const MATCHER = PSE._compile_selector_matcher(SCENE, CROWNS)
const RELATIVE = PSE.Many()
const RELATIVE_MATCHER = PSE._compile_selector_matcher(SCENE, RELATIVE)

Base.@noinline function both_crowns(model, selector, matcher, context)
    ids = PSE._dependency_object_ids(model, selector, matcher, context)
    return length(ids) == 2 && ids[1] == PSE.ObjectId(:crown_1) && ids[2] == PSE.ObjectId(:crown_2)
end

function (@main)(args)
    if length(args) == 1 && only(args) == "nested"
        return NestedCallControl.check(NestedCallControl.TARGETS) ? Cint(0) : Cint(3)
    end
    context = isempty(args) ? PSE.ObjectId(:scene) : PSE.ObjectId(:crown_1)
    both_crowns(SCENE, CROWNS, MATCHER, context) || return Cint(1)
    ids = PSE._dependency_object_ids(SCENE, RELATIVE, RELATIVE_MATCHER, context)
    return length(ids) == 1 && ids[1] === context ? Cint(0) : Cint(2)
end

end
