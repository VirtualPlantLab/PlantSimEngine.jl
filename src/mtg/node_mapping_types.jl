"""
    AbstractNodeMapping

Abstract type for node mapping markers, such as single-node, multi-node, self,
or same-scale mappings.
"""
abstract type AbstractNodeMapping end

"""
    SameScale()

Marker used in multiscale variable mappings when a variable is aliased or
renamed from another variable at the same scale.
"""
struct SameScale <: AbstractNodeMapping end
