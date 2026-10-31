# Optional checked duck-typed numerical status. Canonical registry Status and
# its exact reference carriers remain unchanged and own all public state.
"""
    direct_status_compatible(::Type) = false

An explicit source audit: this kernel accepts the status property protocol
without dispatch/reflection on its concrete row representation. It may borrow
canonical references through refvalue. The checked implementation never assumes
that a backing array retains its length and never applies @inbounds to run!.
"""
direct_status_compatible(::Type) = false
for row in PB_NATIVE_CALL_AUDIT
    T = typeof(row.model)
    @eval direct_status_compatible(::Type{$T}) = true
end

struct NativeDirectStatus{V<:NativeStatusView}
    view::V
end

@inline @generated function _direct_status_get(row::NativeDirectStatus{NativeStatusView{C,I}},
    ::Val{Name}) where {C,I,Name}
    index = findfirst(==(Name), fieldnames(C))
    index === nothing && return :(getproperty(_direct_canonical_status(row), $(QuoteNode(Name))))
    return quote
        view = getfield(row, :view)
        getfield(view.columns, $index)[getfield(view.indices, $index)]
    end
end
@inline @generated function _direct_status_set!(row::NativeDirectStatus{NativeStatusView{C,I}},
    ::Val{Name}, value) where {C,I,Name}
    index = findfirst(==(Name), fieldnames(C))
    index === nothing && return :(setproperty!(_direct_canonical_status(row), $(QuoteNode(Name)), value))
    return quote
        view = getfield(row, :view)
        getfield(view.columns, $index)[getfield(view.indices, $index)] = value
    end
end

@inline Base.@constprop :aggressive Base.getproperty(row::NativeDirectStatus, name::Symbol) =
    _direct_status_get(row, Val(name))
@inline Base.@constprop :aggressive Base.setproperty!(row::NativeDirectStatus, name::Symbol, value) =
    _direct_status_set!(row, Val(name), value)

@inline _direct_canonical_status(row::NativeDirectStatus) = getfield(getfield(row, :view), :backing)
@inline PSE.refvalue(row::NativeDirectStatus, name::Symbol) =
    PSE.refvalue(_direct_canonical_status(row), name)
PSE.refvalues(row::NativeDirectStatus) = PSE.refvalues(_direct_canonical_status(row))
PSE._status_identity(row::NativeDirectStatus) = getfield(getfield(row, :view), :identity)
PSE._status_vars(row::NativeDirectStatus) = PSE._status_vars(_direct_canonical_status(row))
Base.keys(row::NativeDirectStatus) = keys(_direct_canonical_status(row))
Base.values(row::NativeDirectStatus) = values(_direct_canonical_status(row))
Base.propertynames(row::NativeDirectStatus) = propertynames(_direct_canonical_status(row))
Base.length(row::NativeDirectStatus) = length(_direct_canonical_status(row))
Base.eltype(row::NativeDirectStatus) = eltype(_direct_canonical_status(row))
Base.NamedTuple(row::NativeDirectStatus) = NamedTuple(_direct_canonical_status(row))
Base.Tuple(row::NativeDirectStatus) = Tuple(_direct_canonical_status(row))
Base.iterate(row::NativeDirectStatus, state...) = iterate(_direct_canonical_status(row), state...)
Base.firstindex(row::NativeDirectStatus) = firstindex(_direct_canonical_status(row))
Base.lastindex(row::NativeDirectStatus) = lastindex(_direct_canonical_status(row))
Base.indexed_iterate(row::NativeDirectStatus, index::Int, state=1) =
    Base.indexed_iterate(_direct_canonical_status(row), index, state)
@inline Base.getindex(row::NativeDirectStatus, name::Symbol) = getproperty(row, name)
Base.getindex(row::NativeDirectStatus, index::Int) = _direct_canonical_status(row)[index]
@inline Base.setindex!(row::NativeDirectStatus, value, name::Symbol) = setproperty!(row, name, value)
Base.setindex!(row::NativeDirectStatus, value, index::Int) =
    setindex!(_direct_canonical_status(row), value, index)
Base.show(io::IO, row::NativeDirectStatus) = show(io, _direct_canonical_status(row))
Base.show(io::IO, mime::MIME"text/plain", row::NativeDirectStatus) =
    show(io, mime, _direct_canonical_status(row))
_direct_comparison_status(row::NativeDirectStatus) = _direct_canonical_status(row)
_direct_comparison_status(row::PSE.Status) = row
Base.:(==)(left::NativeDirectStatus, right::Union{NativeDirectStatus,PSE.Status}) =
    _direct_canonical_status(left) == _direct_comparison_status(right)
Base.:(==)(left::PSE.Status, right::NativeDirectStatus) =
    left == _direct_canonical_status(right)

@inline _native_kernel_status(view, model, ::Val{:refs}) = _native_status(view)
@inline _native_kernel_status(view, model, ::Val{:direct}) = _native_status(view)
@inline function _native_kernel_status(view::NativeStatusView, model, ::Val{:direct})
    return direct_status_compatible(typeof(model)) ? NativeDirectStatus(view) : _native_status(view)
end
