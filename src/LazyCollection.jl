"""
    LayeredCollections.LazyOperationType(f)

This needs to be overrided for custom operator.
Return `LazyAddLikeOperator()` or `LazyMulLikeOperator()`.
"""
abstract type LazyOperationType end
struct LazyAddLikeOperator <: LazyOperationType end
struct LazyMulLikeOperator <: LazyOperationType end
LazyOperationType(::Any) = LazyAddLikeOperator()
@pure function LazyOperationType(f::Function)
    Base.operator_precedence(Symbol(f)) ≥ Base.operator_precedence(:*) ?
        LazyMulLikeOperator() : LazyAddLikeOperator()
end

# add `Ref`s
lazyable(::LazyOperationType, c, ::Val) = Ref(c)
lazyable(::LazyOperationType, c::Base.RefValue, ::Val) = c
lazyable(::LazyAddLikeOperator, c::AbstractCollection{layer}, ::Val{layer}) where {layer} = c
lazyable(::LazyAddLikeOperator, c::AbstractCollection, ::Val) = throw(ArgumentError("addition like operation with different collections is not allowded"))
lazyable(::LazyMulLikeOperator, c::AbstractCollection{layer}, ::Val{layer}) where {layer} = c
@generated function lazyables(f, args...)
    layer = maximum(whichlayer, args)
    Expr(:tuple, [:(lazyable(LazyOperationType(f), args[$i], Val($layer))) for i in 1:length(args)]...)
end
lazyables(f, args′::Union{Base.RefValue, AbstractCollection{layer}}...) where {layer} = args′ # already "lazyabled"

# extract arguments without `Ref`
_extract_norefs(ret::Tuple) = ret
_extract_norefs(ret::Tuple, x::Ref, y...) = _extract_norefs(ret, y...)
_extract_norefs(ret::Tuple, x, y...) = _extract_norefs((ret..., x), y...)
extract_norefs(x...) = _extract_norefs((), x...)
extract_norefs(x::AbstractCollection...) = x

"""
    return_layer(f, args...)

Get returned layer.
"""
function return_layer(f, args...)
    args′ = extract_norefs(lazyables(f, args...)...)
    return_layer(LazyOperationType(f), args′...)
end
return_layer(::LazyOperationType, ::AbstractCollection{layer}...) where {layer} = layer

"""
    return_length(f, args...)

Get returned dimensions.
"""
function return_length(f, args...)
    args′ = extract_norefs(lazyables(f, args...)...)
    return_length(LazyOperationType(f), args′...)
end
check_length(x::Int) = x
check_length(x::Int, y::Int, z::Int...) = (@assert x == y; check_length(y, z...))
return_length(::LazyOperationType, args::AbstractCollection{layer}...) where {layer} = check_length(map(length, args)...)

@generated function return_type(f, args...)
    :($(Base._return_type(_propagate_lazy, (f, eltype.(args)...)))) # `_propagate_lazy` is defined at getindex
end


struct LazyCollection{layer, T, F, Args <: Tuple} <: AbstractCollection{layer, T}
    f::F
    args::Args
    len::Int
    function LazyCollection{layer, T, F, Args}(f::F, args::Args, len::Int) where {layer, T, F, Args}
        new{layer::Int, T, F, Args}(f, args, len)
    end
end

@inline function LazyCollection{layer, T}(f::F, args::Args, len::Int) where {layer, T, F, Args}
    LazyCollection{layer, T, F, Args}(f, args, len)
end

@generated function LazyCollection(f, args...)
    quote
        args′ = lazyables(f, args...)
        norefs = extract_norefs(args′...)
        layer = return_layer(f, norefs...)
        len = return_length(f, norefs...)
        T = return_type(f, args′...)
        LazyCollection{layer, T}(f, args′, len)
    end
end
lazy(f, args...) = LazyCollection(f, args...)

Base.length(c::LazyCollection) = c.len

# this propagates lazy operation when any AbstractCollection is found
# otherwise just normally call function `f`.
@generated function _propagate_lazy(f, args...)
    any([t <: AbstractCollection for t in args]) ?
        :(LazyCollection(f, args...)) : :(f(args...))
end
_propagate_lazy(f, arg) = f(arg) # this prevents too much propagation
@inline _getindex(c::AbstractCollection, i::Int) = (@_propagate_inbounds_meta; c[i])
@inline _getindex(c::Base.RefValue, i::Int) = c[]
@generated function Base.getindex(c::LazyCollection{<: Any, <: Any, <: Any, Args}, i::Int) where {Args}
    exps = [:(_getindex(c.args[$j], i)) for j in 1:length(Args.parameters)]
    quote
        @_inline_meta
        @boundscheck checkbounds(c, i)
        @inbounds _propagate_lazy(c.f, $(exps...))
    end
end

# convert to array
# this is needed for matrix type because `collect` is called by default
function Base.Array(c::LazyCollection)
    v = first(c)
    A = Array{typeof(v)}(undef, size(c))
    for i in eachindex(A)
        @inbounds A[i] = c[i]
    end
    A
end

show_type_name(c::LazyCollection{layer, T}) where {layer, T} = "LazyCollection{$layer, $T}"
