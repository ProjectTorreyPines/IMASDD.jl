using Printf
import AbstractTrees
import OrderedCollections
import StaticArraysCore
document[:Base] = Symbol[]

#= ============================ =#
#  IDS and IDSvector structures  #
#= ============================ =#
# this structure is used when returning generators to avoid specialization
# of the generator on the many concrete IDS types that are in IMASDD
struct NoSpecialize
    specialized_data_structure::Any
end

function Base.getproperty(ns::NoSpecialize, field::Symbol)
    return getfield(ns, :specialized_data_structure)
end

#= ==== =#
#  info  #
#= ==== =#
"""
    info(uloc::String, extras::Bool=true)

Return information of a node in the IMAS data structure, possibly including extra structures
"""
function info(uloc::String, extras::Bool=true)::Info
    if "$uloc[:]" ∈ keys(_all_info)
        nfo = _all_info["$uloc[:]"]
    else
        nfo = _all_info[uloc]
    end
    if !extras && nfo.extras
        error("$uloc is an extra structure")
    end
    return nfo
end

"""
    info(@nospecialize(ids::Union{IDS,IDSvector}), field::Symbol)::Dict{String,Any}

Return information of a filed of an IDS
"""
function info(@nospecialize(ids::Union{IDS,IDSvector,Type}), field::Symbol)::Info
    return info(ulocation(ids, field))
end

export info
push!(document[:Base], :info)

"""
    units(uloc::String)::String

Return string with units for a given IDS location
"""
function units(uloc::String)::String
    return info(uloc).units
end

"""
    units(ids::IDS, field::Symbol)::String

Return string with units for a given IDS field
"""
function units(@nospecialize(ids::IDS), field::Symbol)::String
    return units(ulocation(ids, field))
end

export units
push!(document[:Base], :units)

struct Coordinates{T}
    names::Vector{String}
    fills::Vector{Bool}
    values::Vector{Vector{T}}
end

"""
    coordinates(@nospecialize(ids::IDS), field::Symbol; coord_leaves::Union{Nothing,Vector{Symbol}}=nothing)

Return two lists, one of coordinate names and the other with their values in the data structure

Coordinate value is `nothing` when the data does not have a coordinate

Coordinate value is `missing` if the coordinate is missing in the data structure

Use `coord_leaves` to override fetching coordinates of a given field
"""
function coordinates(@nospecialize(ids::IDS), field::Symbol; coord_leaves::Union{Nothing,Vector{<:Union{Nothing,Symbol}}}=nothing)
    T = eltype(ids)
    coord_names = String[coord for coord in info(ids, field).coordinates]
    coord_fills = Bool[]
    coord_values = Vector{T}[]
    for (k, coord) in enumerate(coord_names)
        if occursin("...", coord)
            if (coord_leaves === nothing) || (coord_leaves[k] === nothing)
                push!(coord_fills, true)
                push!(coord_values, T[])
            else
                coord_names[k] = ulocation(ids, coord_leaves[k])
                push!(coord_fills, true)
                push!(coord_values, getproperty(ids, coord_leaves[k]))
            end
        else
            coord_path, true_coord_leaf = rsplit(coord, "."; limit=2)
            h = goto(ids, u2fs(coord_path))
            if typeof(h) <: IMASdetachedHead
                push!(coord_fills, false)
                push!(coord_values, T[])
            else
                if (coord_leaves === nothing) || (coord_leaves[k] === nothing)
                    h = getproperty(h, Symbol(true_coord_leaf), missing)
                else
                    coord_leaf = coord_leaves[k]
                    coord_names[k] = "$(coord_path).$(coord_leaves[k])"
                    h = getproperty(h, Symbol(coord_leaf), missing)
                end
                # add value to the coord_values
                if ismissing(h)
                    push!(coord_fills, false)
                    push!(coord_values, T[])
                else
                    push!(coord_fills, true)
                    if typeof(h) <: Vector{T}
                        push!(coord_values, h)
                    else
                        # this is to handle cases where coordinates are not T
                        # eg. dd.controllers.linear_controller[:].pid.d.data
                        # maybe in the future we can allow non-T coordinates
                        push!(coord_values, T.(1:length(h)))
                    end
                end
            end
        end
    end
    return Coordinates{T}(coord_names, coord_fills, coord_values)
end

export coordinates
push!(document[:Base], :coordinates)

#= ========== =#
#  access log  #
#= ========== =#
mutable struct AccessLog
    enabled::Bool
    read::Set{String}
    expr::Set{String}
    write::Set{String}
end

"""
    IMASDD.access_log

    IMASDD.access_log.enable = true / false

    @show IMASDD.access_log

    empty!(IMASDD.access_log) # to reset

Track access to the data dictionary
"""
const access_log = AccessLog(false, Set(String[]), Set(String[]), Set(String[]))

function Base.empty!(access_log::AccessLog)
    empty!(access_log.read)
    empty!(access_log.expr)
    empty!(access_log.write)
    return nothing
end

function Base.show(io::IO, access_log::AccessLog)
    for field in (:read, :expr, :write)
        log = getfield(access_log, field)
        for k in sort!(collect(log))
            println(io, "$field: $k")
        end
        println(io, "")
    end
end

export access_log
push!(document[:Base], :access_log)

#= === =#
#  IDS  #
#= === =#
"""
    getproperty(@nospecialize(ids::IDS), field::Symbol)

Return IDS value for requested field
"""
function Base.getproperty(@nospecialize(ids::IDS), field::Symbol)
    value = _getproperty(ids, field)
    if typeof(value) <: Exception
        throw(value)
    end
    return value
end

"""
    getproperty(@nospecialize(ids::IDS), field::Symbol, @nospecialize(default::Any))

Return IDS value for requested field or `default` if field is missing

NOTE: This is useful because accessing a `missing` field in an IDS would raise an error
"""
function Base.getproperty(@nospecialize(ids::IDS), field::Symbol, @nospecialize(default::Any))
    value = _getproperty(ids, field)
    if typeof(value) <: Exception
        return default
    else
        return value
    end
end

export getproperty
push!(document[:Base], :getproperty)

"""
    getraw(@nospecialize(ids::IDS), field::Symbol)

Returns data, expression function, or missing

  - Does not raise an error on missing data, returns missing
  - Does not evaluate expressions
"""
function getraw(@nospecialize(ids::IDS), field::Symbol)
    @assert field ∉ private_fields error("Use `getfield(ids, :$field)` instead of getraw(ids, :$field)")

    value = getfield(ids, field)

    if typeof(value) <: Union{IDS,IDSvector}
        # nothing to do for data structures
        return value

    elseif field == :global_time
        # global time
        return value

    elseif hasdata(ids, field)
        # has data
        return value

    elseif hasexpr(ids, field)
        # has an expression
        return getexpr(ids, field)

    else
        # missing data
        return missing
    end
end

"""
    isempty(@nospecialize(ids::IDSvector))::Bool

returns true if IDSvector is empty
"""
function Base.isempty(@nospecialize(ids::IDSvector))::Bool
    # we define this function explicitly do a @nospecialize
    return length(ids) == 0
end

"""
    isempty(@nospecialize(ids::IDS); include_expr::Bool=false, eval_expr::Bool=false)::Bool

Returns true if none of the IDS fields downstream have data (or expressions)

NOTE: By default it does not include nor evaluate expressions
"""
function Base.isempty(@nospecialize(ids::IDS); include_expr::Bool=false, eval_expr::Bool=false)::Bool
    if hasdata(ids)
        return false
    end
    if include_expr
        if eval_expr
            np = NoSpecialize(ids)
            return !any(!isempty(np.ids, field; include_expr, eval_expr) for field in keys(np.ids))
        else
            return !hasexpr(ids)
        end
    else
        return true
    end
end

"""
    isempty(@nospecialize(ids::IDS), field::Symbol; include_expr::Bool=false, eval_expr::Bool=false)::Bool

Returns true if the ids field has no data (or expression)

NOTE: By default it does not include nor evaluate expressions
"""
function Base.isempty(@nospecialize(ids::IDS), field::Symbol; include_expr::Bool=false, eval_expr::Bool=false)::Bool
    v = getfield(ids, field)
    if typeof(v) <: IDSvector # filled arrays of structures
        return isempty(v)
    elseif typeof(v) <: IDS # filled structures
        return isempty(v; include_expr, eval_expr)
    elseif eval_expr
        return getproperty(ids, field, missing) === missing
    elseif include_expr
        return !(hasdata(ids, field) || hasexpr(ids, field))
    else
        return !hasdata(ids, field)
    end
end

export isempty
push!(document[:Base], :isempty)

function _getproperty(@nospecialize(ids::IDSraw), field::Symbol)
    if field ∈ private_fields
        error("Use `getfield(ids, :$field)` instead of `ids.$field`")
    end
    value = getfield(ids, field)
    if hasdata(ids, field)
        return value
    elseif typeof(value) <: Union{IDS,IDSvector}
        return value
    else
        return IMASmissingDataException(ids, field)
    end
end

function _getproperty(@nospecialize(ids::IDS), field::Symbol)
    if field ∈ private_fields
        error("Use `getfield(ids, :$field)` instead of `ids.$field`")
    elseif !hasfield(typeof(ids), field)
        error("type $(typeof(ids)) has no field `$(field)`\nDid you mean: $(collect(keys(ids))))")
    end

    value = getfield(ids, field)

    if field === :global_time
        # pass
        return value

    elseif typeof(value) <: Union{IDS,IDSvector}
        # nothing to do for data structures
        return value

    elseif hasdata(ids, field)
        # has data
        return value

    elseif !getfield(ids, :_frozen)
        # expressions
        uloc = ulocation(ids, field)
        for (onetime, expressions) in zip((true, false), (get_expressions(Val{:onetime}), get_expressions(Val{:dynamic})))
            if uloc ∈ keys(expressions)
                func = expressions[uloc]
                value = exec_expression_with_ancestor_args(ids, field, func)
                if typeof(value) <: Exception
                    # check in the reference
                    return value
                else
                    if access_log.enabled
                        push!(access_log.expr, uloc)
                    end
                    if onetime # onetime_expression
                        #println("onetime_expression: $(location(ids, field))")
                        setraw!(ids, field, value)
                        expression_onetime_weakref[objectid(ids)] = WeakRef(ids)
                    end
                    return value
                end
            end
        end
    end

    # missing data and no available expression
    return IMASmissingDataException(ids, field)

end

function setraw!(@nospecialize(ids::IDS), field::Symbol, v::SubArray)
    return setraw!(ids, field, collect(v))
end

function setraw!(@nospecialize(ids::IDS), field::Symbol, v::Any)
    if field in private_fields
        error("Use `setfield!(ids, :$field, ...)` instead of setraw!(ids, :$field ...)")
    end
    tp = fieldtype(typeof(ids), field)
    if typeof(v) <: tp
        tmp = setfield!(ids, field, v)
        add_filled(ids, field)
        if access_log.enabled && !(typeof(v) <: Union{IDS,IDSvector})
            push!(access_log.write, ulocation(ids, field))
        end
        return tmp
    else
        error("$(typeof(v)) is the wrong type for `$(ulocation(ids, field))`, it should be $(tp)")
    end
end

"""
    add_filled(@nospecialize(ids::IDS), field::Symbol)

Utility function to set the _filled field of an IDS and the upstream parents
"""
function add_filled(@nospecialize(ids::IDS), field::Symbol)
    if field !== :global_time
        push!(getfield(ids, :_filled), field)
    end
    return add_filled(ids)
end

"""
    add_filled(@nospecialize(ids::Union{IDS,IDSvector}))

Utility function to set the _filled field of the upstream parents
"""
function add_filled(@nospecialize(ids::Union{IDS,IDSvector}))
    pids = getfield(ids, :_parent).value
    if typeof(pids) <: IDS
        filled = getfield(pids, :_filled)
        for pfield in fieldnames(typeof(pids))
            if ids === getfield(pids, pfield)
                if pfield ∉ filled
                    add_filled(pids, pfield)
                end
                break
            end
        end
    end
end

"""
    del_filled(@nospecialize(ids::IDS), field::Symbol)

Utility function to unset the _filled field of an IDS
"""
function del_filled(@nospecialize(ids::IDS), field::Symbol)
    delete!(getfield(ids, :_filled), field)
    return ids
end

function del_filled(@nospecialize(ids::Union{IDS,IDSvector}))
    pids = getfield(ids, :_parent).value
    if typeof(pids) <: IDS
        for pfield in keys(pids)
            if ids === getfield(pids, pfield)
                delete!(getfield(pids, :_filled), pfield)
                break
            end
        end
    end
end

"""
    Base.setproperty!(ids::IDS, field::Symbol, v; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)
"""
function Base.setproperty!(@nospecialize(ids::IDS), field::Symbol, v::Any; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)
    return setraw!(ids, field, v)
end

"""
    Base.setproperty!(@nospecialize(ids::IDS), field::Symbol, v::AbstractArray{<:IDS}; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)

Handle setproperty of entire vectors of IDS structures at once (ids.field is of type IDSvector)
"""
function Base.setproperty!(@nospecialize(ids::IDS), field::Symbol, v::AbstractArray{<:IDS}; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)
    orig = getfield(ids, field)
    empty!(orig)
    append!(orig, v)
    add_filled(ids, field)
    return orig
end

"""
    Base.setproperty!(
        @nospecialize(ids::IDS),
        field::Symbol,
        v::Union{AbstractRange,StaticArraysCore.SVector,StaticArraysCore.MVector};
        skip_non_coordinates::Bool=false,
        error_on_missing_coordinates::Bool=true
    )

Convert abstract ranges and static arrays to vectors
"""
function Base.setproperty!(
    @nospecialize(ids::IDS),
    field::Symbol,
    v::Union{AbstractRange,StaticArraysCore.SVector,StaticArraysCore.MVector};
    skip_non_coordinates::Bool=false,
    error_on_missing_coordinates::Bool=true
)
    v = collect(v)
    return setproperty!(ids, field, v; skip_non_coordinates, error_on_missing_coordinates)
end

"""
    Base.setproperty!(@nospecialize(ids::IDS), field::Symbol, v::AbstractArray; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)

Ensures coordinates are set before the data that depends on those coordinates.
If `skip_non_coordinates` is set, then fields that are not coordinates will be silently skipped.
"""
function Base.setproperty!(@nospecialize(ids::IDS), field::Symbol, v::AbstractArray; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)
    if field ∉ getfield(ids, :_filled) && error_on_missing_coordinates
        # figure out the coordinates
        coords = coordinates(ids, field)

        # skip non coordinates
        if skip_non_coordinates && any(!occursin("...", c_name) for c_name in coords.names)
            return nothing
        end

        # do not allow assigning data before coordinates
        if !all(coords.fills)
            error("Can't assign data to `$(location(ids, field))` before $(coords.names)")
        end
    end
    return setraw!(ids, field, v)
end

function Base.setproperty!(@nospecialize(ids::IDSraw), field::Symbol, v::AbstractArray; skip_non_coordinates::Bool=false, error_on_missing_coordinates::Bool=true)
    return setraw!(ids, field, v)
end

function Base.setproperty!(
    @nospecialize(ids::IDSvector),
    field::Symbol,
    @nospecialize(v::IDSvectorElement);
    skip_non_coordinates::Bool=false,
    error_on_missing_coordinates::Bool=true
)
    setfield!(v, :_parent, WeakRef(ids))
    return setraw!(ids, field, v)
end

function Base.setproperty!(
    @nospecialize(ids::IDS),
    field::Symbol,
    @nospecialize(v::Union{IDS,IDSvector});
    skip_non_coordinates::Bool=false,
    error_on_missing_coordinates::Bool=true
)
    setfield!(v, :_parent, WeakRef(ids))
    return setraw!(ids, field, v)
end

export setproperty!
push!(document[:Base], :setproperty!)

#= ======== =#
#  deepcopy  #
#= ======== =#
function Base.deepcopy(@nospecialize(ids::Union{IDS,IDSvector}))
    ids1 = Base.deepcopy_internal(ids, Base.IdDict())
    setfield!(ids1, :_parent, WeakRef(nothing))
    return ids1
end

#= ===== =#
#  fill!  #
#= ===== =#
function Base.fill!(ids_new::T, ids::T) where {T<:IDS}
    for field in getfield(ids, :_filled)
        value = getraw(ids, field)
        if typeof(getfield(ids, field)) <: IDS
            fill!(getfield(ids_new, field), value)
            add_filled(ids_new, field)
        elseif typeof(getfield(ids, field)) <: IDSvector
            fill!(getfield(ids_new, field), value)
        else
            setraw!(ids_new, field, deepcopy(value))
        end
    end
    return ids_new
end

function Base.fill!(ids_new::T, ids::T) where {T<:IDSvector}
    if !isempty(ids)
        resize!(ids_new, length(ids))
        for k in 1:length(ids)
            fill!(ids_new[k], ids[k])
        end
    end
    return ids_new
end

#= ========= =#
#  IDSvector  #
#= ========= =#
function Base.size(@nospecialize(ids::IDSvector))
    return size(ids._value)
end

function Base.length(@nospecialize(ids::IDSvector))
    return length(ids._value)
end

function Base.getindex(@nospecialize(ids::IDSvector{T}), i::Int)::T where {T<:IDSvectorElement}
    if 1 <= i <= length(ids._value)
        return ids._value[i]
    elseif i < 1
        error("Attempt to access $(length(ids))-element $(typeof(ids)) at index [$i]. Need start indexing at 1.")
    else
        error("Attempt to access $(length(ids))-element $(typeof(ids)) at index [$i]. Need to `resize!(ids, $i)`.")
    end
end

function Base.setindex!(@nospecialize(ids::IDSvector{T}), @nospecialize(v::T), i::Integer)::T where {T<:IDSvectorElement}
    ids._value[i] = v
    setfield!(v, :_parent, WeakRef(ids))
    add_filled(ids)
    return v
end

function Base.push!(@nospecialize(ids::IDSvector{T}), @nospecialize(v::T))::IDSvector{T} where {T<:IDSvectorElement}
    setfield!(v, :_parent, WeakRef(ids))
    push!(ids._value, v)
    add_filled(ids)
    return ids
end

function Base.append!(@nospecialize(ids::IDSvector{T}), @nospecialize(vv::AbstractVector{<:T}))::IDSvector{T} where {T<:IDSvectorElement}
    for v in vv
        push!(ids, v)
    end
    return ids
end

function Base.push!(@nospecialize(ids::IDSvector{T}), @nospecialize(v::Any))::IDSvector{T} where {T<:IDSvectorElement}
    return error("`push!` on $(location(ids)) must be of type $(T) and is instead of type $(typeof(v))")
end

function Base.pushfirst!(@nospecialize(ids::IDSvector{T}), @nospecialize(v::T))::IDSvector{T} where {T<:IDSvectorElement}
    setfield!(v, :_parent, WeakRef(ids))
    pushfirst!(ids._value, v)
    add_filled(ids)
    return ids
end

function Base.insert!(@nospecialize(ids::IDSvector{T}), i, @nospecialize(v::T))::T where {T<:IDSvectorElement}
    setfield!(v, :_parent, WeakRef(ids))
    insert!(ids._value, i, v)
    add_filled(ids)
    return v
end

function Base.pop!(@nospecialize(ids::IDSvector{T}))::T where {T<:IDSvectorElement}
    tmp = pop!(ids._value)
    if isempty(ids)
        del_filled(ids)
    end
    return tmp
end

"""
    merge!(@nospecialize(target_ids::T), @nospecialize(source_ids::T))::T where {T<:IDS}
"""
function Base.merge!(@nospecialize(target_ids::T), @nospecialize(source_ids::T))::T where {T<:IDS}
    for field in keys_no_missing(source_ids; include_expr=false, eval_expr=false)
        value = getproperty(source_ids, field)
        setproperty!(target_ids, field, value; error_on_missing_coordinates=false)
    end
    return target_ids
end

function Base.merge!(@nospecialize(target_ids::T), @nospecialize(source_ids::T))::T where {T<:IDSvector}
    for (k, value) in enumerate(source_ids)
        if k <= length(target_ids)
            target_ids[k] = value
        else
            push!(target_ids, value)
        end
    end
    return target_ids
end

"""
    index(@nospecialize(ids::IDSvectorElement))

Returns index of the IDSvectorElement in the parent IDSvector
"""
function index(@nospecialize(ids::IDSvectorElement))::Int
    if parent(ids) === nothing
        return 0
    end
    n = findlast(k === ids for k in parent(ids)._value)
    if n === nothing
        # this happens when doing freeze(ids)
        return 0
    else
        return n
    end
end

function index(@nospecialize(ids::IDS))::Int
    # this function does not make sense per se
    # but it solves an issue with type stability
    return 0
end

export index
push!(document[:Base], :index)

#= ===== =#
#  Utils  #
#= ===== =#
function _set_conditions(@nospecialize(ids::IDS), conditions::Pair{String}...)
    for (path, value) in conditions
        h = ids
        for p in i2p(path)
            if isdigit(p[1])
                n = parse(Int, p)
                if n > length(h)
                    resize!(h, n)
                end
                h = h[n]
            else
                p = Symbol(p)
                if ismissing(h, p)
                    setproperty!(h, p, value)
                end
                h = getproperty(h, p)
            end
        end
    end
    return ids
end

function Base.findall(@nospecialize(ids::IDSvector), condition::Pair{String}, conditions::Pair{String}...)
    conditions = vcat(condition, collect(conditions))
    if isempty(ids)
        return eltype(ids)[]
    end
    matches = _match(ids, conditions)
    return values(matches)
end

function _match(@nospecialize(ids::IDSvector), conditions)
    matches = Dict()
    for (k, item) in enumerate(ids)
        match = true
        for (path, value) in conditions
            h = item
            for p in i2p(path)
                if isdigit(p[1])
                    n = parse(Int, p)
                    if n > length(h)
                        match = false
                        break
                    end
                    h = h[n]
                else
                    p = Symbol(p)
                    if ismissing(h, p)
                        match = false
                        break
                    end
                    h = getproperty(h, p)
                end
            end
            if h != value
                match = false
                break
            end
        end
        if match
            matches[k] = item
        end
    end
    return matches
end

#= ==== =#
#  keys  #
#= ==== =#
"""
    _common_base_string(s1::String, s2::String)::Vector{String}

Given two strings it returns a tuple of 3 strings that is the common initial part, and then the remaining parts
"""
function _common_base_string(s1::String, s2::String)::Tuple{String,String,String}
    index = nothing
    for k in 1:min(length(s1), length(s2))
        sub = SubString(s2, 1, k)
        if startswith(s1, sub)
            index = k
        end
    end
    if index === nothing
        return "", s1, s2
    else
        return SubString(s1, 1, index), SubString(s1, index + 1, length(s1)), SubString(s2, index + 1, length(s2))
    end
end

"""
    keys(@nospecialize(ids::IDS))

Returns generator of fields in a IDS whether they are filled with data or not
"""
function Base.keys(@nospecialize(ids::IDS))
    ns = NoSpecialize(ids)
    return (field for field in fieldnames_(typeof(ns.ids)))
end

"""
    keys_no_missing(@nospecialize(ids::IDS); include_expr::Bool=true, eval_expr::Bool=false)

Returns generator of fields with data in a IDS

NOTE: By default it includes expressions, but does not evaluate them
"""
function keys_no_missing(@nospecialize(ids::IDS); include_expr::Bool=true, eval_expr::Bool=false)
    ns = NoSpecialize(ids)
    return (field for field in keys(ns.ids) if !isempty(ns.ids, field; include_expr, eval_expr))
end

export keys_no_missing
push!(document[:Base], :keys_no_missing)

function Base.keys(@nospecialize(ids::IDSvector))::UnitRange{Int}
    return 1:length(ids)
end

function Base.iterate(@nospecialize(ids::IDS))
    allkeys = collect(keys(ids))
    allvalues = collect(values(ids))
    return (allkeys[1], allvalues[1]), (allkeys, allvalues, 2)
end

function Base.iterate(@nospecialize(ids::IDS), state::Tuple{Vector{Symbol},Int})
    allkeys, allvalues, k = state
    if k > length(allkeys)
        return nothing
    else
        return (allkeys[k], allvalues[k]), (allkeys, allvalues, k + 1)
    end
end

"""
    values(@nospecialize(ids::IDS); default::Any=missing

Returns list of values in a IDS

`default` is assigned when a the field in the IDS is not filled with data
"""
function Base.values(@nospecialize(ids::IDS); default::Any=missing)
    ns = NoSpecialize(ids)
    return (getproperty(ns.ids, field, default) for field in keys(ns.ids))
end

"""
    fieldtypes_(@nospecialize(ids_type::Type{T})) where {T<:IDS} 

Returns fieldtypes of an IDS, excluding the ones starting with an underscore
"""
function fieldtypes_(@nospecialize(ids_type::Type{T})) where {T<:IDS}
    ns = NoSpecialize(ids_type)
    return (ftype for (field, ftype) in zip(fieldnames(ns.ids_type), fieldtypes(ns.ids_type)) if field ∉ private_fields && field !== :global_time)
end

"""
    fieldnames_(@nospecialize(ids_type::Type{T})) where {T<:IDS} 

Returns fieldnames of an IDS, excluding the ones starting with an underscore
"""
function fieldnames_(@nospecialize(ids_type::Type{T})) where {T<:IDS}
    ns = NoSpecialize(ids_type)
    return (field for field in fieldnames(ns.ids_type) if field ∉ private_fields && field !== :global_time)
end

"""
    fieldindex_(@nospecialize(ids_type::Type), field::Symbol)

Returns index of field in fieldnames of an IDS, excluding the ones starting with an underscore
"""
function fieldindex_(@nospecialize(ids_type::Type), field::Symbol)
    ns = NoSpecialize(ids_type)
    k = 0
    for field in fieldnames(ns.ids_type)
        if field ∉ private_fields && field !== :global_time
            k += 1
            if field === field
                return k
            end
        end
    end
    return error("`$(fs2u(ids_type))` does not have field `$field`")
end

#= ====== =#
#  empty!  #
#= ====== =#
function Base.empty!(@nospecialize(ids::T))::T where {T<:IDS}
    tmp = typeof(ids)()
    for item in fieldnames(typeof(ids))
        if item === :_filled
            empty!(getfield(ids, :_filled))
        elseif item === :_in_expression
            empty!(getfield(ids, :_in_expression))
        elseif item !== :_parent
            value = getfield(tmp, item)
            if typeof(value) <: Union{IDS,IDSvector}
                setfield!(value, :_parent, WeakRef(ids))
            end
            setfield!(ids, item, value)
        end
    end
    return ids
end

function Base.empty!(@nospecialize(ids::T), field::Symbol) where {T<:IDS}
    value = getfield(ids, field)
    if typeof(value) <: Union{IDS,IDSvector}
        empty!(getfield(ids, field))
    else
        if typeof(value) <: Vector
            setfield!(ids, field, typeof(value)())
        end
    end
    del_filled(ids, field)
    return value
end

function Base.empty!(@nospecialize(ids::T))::T where {T<:IDSvector}
    empty!(ids._value)
    return ids
end

#= ======= =#
#  resize!  #
#= ======= =#
function Base.resize!(@nospecialize(ids::IDSvector{T}))::T where {T<:IDSvectorTimeElement}
    time0 = global_time(ids)
    return resize!(ids, time0)
end

function Base.resize!(@nospecialize(ids::IDSvector{T}), time0::Float64)::T where {T<:IDSvectorTimeElement}
    time = time_array_local(ids)
    if isempty(ids) || (time0 > time[end])
        k = length(ids) + 1
    elseif time0 == time[end]
        k = length(ids)
    else
        error("Cannot resize structure at time $time0 for a time array structure already ranging between $(time[1]) and $(time[end])")
    end

    resize!(ids, k)
    ids[k].time = time0 # note IDSvectorTimeElement should always have a .time field

    unifm_time = time_array_parent(ids)
    if isempty(unifm_time) || time0 != unifm_time[end]
        push!(unifm_time, time0)
    end

    return ids[k]
end

function Base.resize!(@nospecialize(ids::T), n::Int; wipe::Bool=true)::T where {T<:IDSvector{<:IDSvectorElement}}
    if n > length(ids)
        for k in length(ids):n-1
            push!(ids, eltype(ids)())
        end
    elseif n < length(ids)
        for k in n:length(ids)-1
            pop!(ids)
        end
    end
    if wipe && !isempty(ids)
        empty!(ids[end])
    end
    if isempty(ids)
        del_filled(ids)
    end
    return ids
end

"""
    Base.resize!(@nospecialize(ids::IDSvector{T}), condition::Pair{String}, conditions::Pair{String}...; wipe::Bool=true, error_multiple_matches::Bool=true)::T where {T<:IDSvectorElement}

Resize if a set of conditions are not met.

If wipe=true and an entry matching the condition is found, then the content of the matching IDS is emptied.

Either way, the IDS is populated with the conditions.

NOTE: `error_multiple_matches` will delete all extra entries matching the conditions.

Returns the selected IDS
"""
function Base.resize!(
    @nospecialize(ids::IDSvector{T}),
    condition::Pair{String},
    conditions::Pair{String}...;
    wipe::Bool=true,
    error_multiple_matches::Bool=true
)::T where {T<:IDSvectorElement}

    conditions = vcat(condition, collect(conditions))
    if isempty(ids)
        return _set_conditions(resize!(ids, 1; wipe)[1], conditions...)
    end
    matches = _match(ids, conditions)
    if length(matches) == 1
        match = first(values(matches))
        if wipe
            empty!(match)
        end
        return _set_conditions(match, conditions...)
    elseif length(matches) > 1
        if error_multiple_matches
            error("Multiple entries $([k for k in keys(matches)]) match resize! conditions: $conditions")
        else
            for (kk, k) in reverse!(collect(enumerate(sort!(collect(keys(matches))))))
                if kk == 1
                    if wipe
                        empty!(matches[k])
                    end
                    return _set_conditions(matches[k], conditions...)
                else
                    deleteat!(ids, k)
                end
            end
        end
    else
        return _set_conditions(resize!(ids, length(ids) + 1; wipe)[length(ids)], conditions...)
    end
end

export resize!
push!(document[:Base], :resize!)

#= ========= =#
#  deleteat!  #
#= ========= =#
function Base.deleteat!(@nospecialize(ids::T), i::Int)::T where {T<:IDSvector}
    deleteat!(ids._value, i)
    if isempty(ids)
        del_filled(ids)
    end
    return ids
end

"""
    Base.deleteat!(@nospecialize(ids::T), condition::Pair{String}, conditions::Pair{String}...)::T where {T<:IDSvector}

If an entry matching the condition is found, then the content of the matching IDS is emptied
"""
function Base.deleteat!(@nospecialize(ids::T), condition::Pair{String}, conditions::Pair{String}...)::T where {T<:IDSvector}
    conditions = vcat(condition, collect(conditions))
    if isempty(ids)
        return ids
    end
    matches = _match(ids, conditions)
    for k in reverse!(sort!(collect(keys(matches))))
        deleteat!(ids, k)
    end
    return ids
end

export deleteat!
push!(document[:Base], :deleteat!)

#= ========= =#
#  ismissing  #
#= ========= =#
"""
    Base.ismissing(@nospecialize(ids::IDS), field::Symbol)::Bool

returns true/false if field is missing in IDS
"""
function Base.ismissing(@nospecialize(ids::IDS), field::Symbol)::Bool
    value = _getproperty(ids, field)
    if typeof(value) <: Exception
        return true
    else
        return false
    end
end

function Base.ismissing(@nospecialize(ids::IDSvector), field::Int)::Bool
    return length(ids) < field
end

function Base.ismissing(@nospecialize(ids::IDS), path::Vector{String})::Bool
    if length(path) == 1
        return ismissing(ids, Symbol(path[1]))
    end
    return ismissing(getfield(ids, Symbol(path[1])), path[2:end])
end

function Base.ismissing(@nospecialize(ids::IDSvector), path::Vector{String})::Bool
    if length(path) == 1
        return ismissing(ids, path[1])
    end
    if isdigit(path[1][1]) && parse(Int, path[1]) <= length(ids)
        n = parse(Int, path[1])
        return ismissing(ids[n], path[2:end])
    else
        return true
    end
end

export ismissing
push!(document[:Base], :ismissing)

#= ==== =#
#  diff  #
#= ==== =#
function _diff_function(v1::T, v2::T, tol::Float64) where {T}
    if v1 in (Inf, -Inf, NaN) && v2 !== v1
        return tol * 2
    else
        return maximum(abs.(v1 .- v2) ./ (tol .+ sum(abs.(v1) .+ abs.(v2)) ./ 2.0 ./ length(v1)))
    end
end

"""
    Base.diff(
        @nospecialize(ids1::T),
        @nospecialize(ids2::T);
        tol::Float64=1E-2,
        recursive::Bool=true,
        verbose::Bool=false) where {T<:IDS}

Compares two IDSs and returns dictionary with differences

NOTE: This function does not evaluate expressions (use `freeze()` on the IDSs to compare values instead of functions)
"""
function Base.diff(
    @nospecialize(ids1::T),
    @nospecialize(ids2::T);
    tol::Float64=1E-2,
    recursive::Bool=true,
    verbose::Bool=false) where {T<:IDS}

    return diff(ids1, ids2, String[], Dict{String,String}(); tol, recursive, verbose)
end

function Base.diff(
    @nospecialize(ids1::T),
    @nospecialize(ids2::T),
    path::Vector{String},
    differences::Dict{String,String};
    tol::Float64=1E-2,
    recursive::Bool=true,
    verbose::Bool=true) where {T<:IDS}

    for field in keys(ids2)
        v1 = getraw(ids1, field)
        v2 = getraw(ids2, field)

        pathname = p2i(String[path; "$field"])
        if typeof(v1) != typeof(v2)
            differences[pathname] = "types:  $(typeof(v1)) --  $(typeof(v2))"
        elseif typeof(v1) <: Missing
            continue
        elseif typeof(v1) <: Function
            if v1 === v2
                continue
            else
                differences[pathname] = "function"
            end
        elseif typeof(v1) <: IDS
            if recursive
                diff(v1, v2, String[path; "$field"], differences; tol, recursive, verbose)
            end
        elseif typeof(v1) <: IDSvector
            if recursive
                if length(v1) != length(v2)
                    differences[pathname] = "length:  $(length(v1)) --  $(length(v2))"
                else
                    for k in 1:length(v1)
                        diff(v1[k], v2[k], String[path; "$field"; "$k"], differences; tol, recursive, verbose)
                    end
                end
            end
        elseif typeof(v1) <: AbstractArray
            if isempty(v1) && isempty(v2)
                continue
            elseif length(v1) != length(v2)
                differences[pathname] = "length:  $(length(v1)) --  $(length(v2))"
            elseif _diff_function(v1, v2, tol) > tol
                differences[pathname] = @sprintf("value: %g", _diff_function(v1, v2, tol))
            end
        elseif typeof(v1) <: Number
            if _diff_function(v1, v2, tol) > tol
                differences[pathname] = "value:  $v1 --  $v2"
            end
        elseif typeof(v1) <: Union{String,Symbol}
            if v1 != v2
                differences[pathname] = "value:  $v1 --  $v2"
            end
        else
            # raise error to force use to handle this explicitly
            error("Unhandled difference: $((pathname, typeof(v1), typeof(v2)))")
        end
        if verbose && (pathname in keys(differences))
            printstyled(pathname; bold=true)
            printstyled(" ➡ "; color=:red)
            println(differences[pathname])
        end
    end
    return differences
end

export diff
push!(document[:Base], :diff)

#= ========== =#
#  navigation  #
#= ========== =#
"""
    top(@nospecialize(ids::Union{IDS,IDSvector}); IDS_is_absolute_top::Bool=true)::Union{IDS,IDSvector}

Return top-level IDS in the hierarchy

Considers IDS as maximum top level if IDS_is_absolute_top=true
"""
function top(@nospecialize(ids::Union{IDS,IDSvector}); IDS_is_absolute_top::Bool=true)::Union{IDS,IDSvector}
    parent_value = getfield(ids, :_parent).value
    if IDS_is_absolute_top && typeof(ids) <: DD
        error("Cannot call top(x::DD, IDS_is_absolute_top=true). Use `IDS_is_absolute_top=false`.")
    elseif parent_value === nothing
        return ids
    elseif IDS_is_absolute_top && (typeof(parent_value) <: DD)
        return ids
    else
        return top(parent_value; IDS_is_absolute_top=IDS_is_absolute_top)
    end
end

"""
    top_ids(@nospecialize(ids::Union{IDS,IDSvector}))::Union{<:IDS,Nothing}

Return top-level IDS in the hierarchy and `nothing` if top level is not a top-level IDS
"""
function top_ids(@nospecialize(ids::Union{IDS,IDSvector}))::Union{<:IDS,Nothing}
    ids = top(ids; IDS_is_absolute_top=true)
    if occursin("__", string(typeof(ids))) || typeof(ids) <: DD
        return nothing
    else
        return ids
    end
end

export top_ids
push!(document[:Base], :top_ids)

"""
    top_dd(@nospecialize(ids::Union{IDS,IDSvector}))::Union{<:DD,Nothing}

Return top-level `dd` in the hierarchy, and `nothing` if top level is not `dd`
"""
function top_dd(@nospecialize(ids::Union{IDS,IDSvector}))::Union{<:DD,Nothing}
    ids = top(ids; IDS_is_absolute_top=false)
    if typeof(ids) <: DD
        return ids
    else
        return nothing
    end
end

export top_dd
push!(document[:Base], :top_dd)

"""
    parent(ids::Union{IDS,IDSvector}; IDS_is_absolute_top::Bool=true)

Return parent IDS/IDSvector in the hierarchy

If `IDS_is_absolute_top=true` then returns `nothing` instead of dd()
"""
function Base.parent(@nospecialize(ids::Union{IDS,IDSvector}); IDS_is_absolute_top::Bool=false)
    parent_value = getfield(ids, :_parent).value
    if IDS_is_absolute_top && typeof(parent_value) <: DD
        return nothing
    else
        return parent_value
    end
end

export parent
push!(document[:Base], :parent)

"""
    goto(@nospecialize(ids::Union{IDS,IDSvector}), loc::String)

Reach location in a given IDS
"""
function goto(@nospecialize(ids::Union{IDS,IDSvector}), loc::String)
    # find common ancestor
    cs, s1, s2 = _common_base_string(f2fs(ids), loc)
    s2 = lstrip(s2, '_')
    cs0 = cs
    if endswith(cs0, "__") && !endswith(cs0, "___")
        cs0 = cs0[1:end-2]
    end
    cs0 = rstrip(cs0, '.')

    # go upstream until common acestor
    h = ids
    while f2fs(h) != cs0
        parent_value = parent(h)
        if parent_value === nothing
            break
        end
        h = parent_value
    end

    # then dive into the location branch
    for p in i2p(s2)
        if isdigit(p[1])
            n = parse(Int, p)
            if n <= length(h)
                h = h[n]
            else
                return IMASdetachedHead("$(f2fs(ids))", loc)
            end
        else
            if hasfield(typeof(h), Symbol(p))
                h = getfield(h, Symbol(p))
            else
                return IMASdetachedHead("$(f2fs(ids))", loc)
            end
        end
    end

    return h
end

"""
    goto(@nospecialize(ids::Union{IDS,IDSvector}), path::Union{AbstractVector,Tuple})

Reach location in a given IDS
"""
function goto(@nospecialize(ids::Union{IDS,IDSvector}), path::Union{AbstractVector,Tuple})
    if isempty(path)
        return ids
    elseif typeof(path[1]) <: Symbol
        return goto(getproperty(ids, path[1]), path[2:end])
    elseif typeof(path[1]) <: Int
        return goto(ids[path[1]], path[2:end])
    else
        error("goto cannot be of type `$(typeof(path[1]))")
    end
end

export goto
push!(document[:Base], :goto)

"""
    leaves(@nospecialize(ids::IDS))

Returns iterator with (filled) leaves in the IDS
"""
function leaves(@nospecialize(ids::IDS))
    return AbstractTrees.Leaves(ids)
end

export leaves
push!(document[:Base], :leaves)

#= ===== =#
#  paths  #
#= ===== =#
"""
    filled_ids_fields(@nospecialize(ids::IDS); eval_expr::Bool=false)::Vector{Tuple{<:IDS,Symbol}}

Returns a vector with tuples pointing to all the (ids, field) that have data downstream
"""
function filled_ids_fields(@nospecialize(ids::IDS); eval_expr::Bool=false)
    ret = OrderedCollections.OrderedDict{String,Tuple{<:IDS,Symbol}}()
    path = location(ids)
    filled_ids_fields!(ret, ids, path; eval_expr)
    return ret
end

function filled_ids_fields!(ret::AbstractDict{String,Tuple{<:IDS,Symbol}}, @nospecialize(ids::IDS), ppath::String; eval_expr::Bool=false)
    for field in keys_no_missing(ids; eval_expr=false)
        path = "$ppath.$field"
        if typeof(getfield(ids, field)) <: Union{IDS,IDSvector}
            filled_ids_fields!(ret, getfield(ids, field), path; eval_expr)
        elseif eval_expr
            value = getproperty(ids, field, missing)
            if value !== missing
                ret[path] = (ids, field)
            end
        else
            ret[path] = (ids, field)
        end
    end
end

function filled_ids_fields!(ret::AbstractDict{String,Tuple{<:IDS,Symbol}}, @nospecialize(ids::IDSvector), ppath::String; eval_expr::Bool=false)
    for k in eachindex(ids)
        path = "$ppath[$k]"
        filled_ids_fields!(ret, ids[k], path; eval_expr)
    end
end

export filled_ids_fields
push!(document[:Base], :filled_ids_fields)

"""
    paths(@nospecialize(ids::IDS); eval_expr::Bool=false)

Returns the locations in the IDS that have data downstream
"""
function paths(@nospecialize(ids::IDS); eval_expr::Bool=false)::Base.KeySet
    return keys(filled_ids_fields(ids; eval_expr))
end

export paths
push!(document[:Base], :paths)

#= ============== =#
#  selective_copy  #
#= ============== =#
"""
    selective_copy!(@nospecialize(h_in::IDS), @nospecialize(h_out::IDS), path::Vector{String}, time0::Float64)

Copies the content of a path from one IDS to another (if the path exists) at a given time0

NOTE:

  - the path is a i2p(ulocation)
  - if time0 is NaN then all times are retained
"""
function selective_copy!(@nospecialize(h_in::IDS), @nospecialize(h_out::IDS), path::Vector{String}, time0::Float64)
    field = Symbol(path[1])
    if length(path) == 1
        raw_value = getraw(h_in, field)
        if !ismissing(h_in, field) # at the leaf
            if !isnan(time0) && typeof(raw_value) <: Vector && (field == :time || any(endswith(coord, ".time") for coord in coordinates(h_in, field).names))
                value = get_time_array(h_in, field, [time0])
            else
                value = getproperty(h_in, field)
            end
            setproperty!(h_out, Symbol(path[end]), value; error_on_missing_coordinates=false)
        end
    else # plain IDS
        selective_copy!(getfield(h_in, field), getfield(h_out, field), path[2:end], time0)
    end
    if typeof(h_out) <: IMASDD.dd
        if time0 != NaN
            h_out.global_time = time0
        else
            h_out.global_time = h_in.global_time
        end
    end
    return nothing
end

function selective_copy!(@nospecialize(h_in::IDSvector), @nospecialize(h_out::IDSvector), path::Vector{String}, time0::Float64)
    if isempty(h_in)
        #pass
    elseif eltype(h_in) <: IDSvectorTimeElement && !isnan(time0)
        h_in = getindex(h_in, time0)
        if isempty(h_out)
            resize!(h_out, time0)
        end
        h_out = getindex(h_out, time0)
        selective_copy!(h_in, h_out, path[2:end], time0)
    elseif length(path) > 1
        if isempty(h_out)
            resize!(h_out, length(h_in))
        end
        for k in 1:length(h_in)
            selective_copy!(getindex(h_in, k), getindex(h_out, k), path[2:end], time0)
        end
    end
    return nothing
end

export selective_copy!
push!(document[:Base], :selective_copy!)

#= ================ =#
#  selective_delete  #
#= ================ =#
"""
    selective_delete!(@nospecialize(h_in::IDS), path::Vector{String})

Deletes a path from one IDS

NOTE:

  - the path is a i2p(ulocation)
"""
function selective_delete!(@nospecialize(h_in::IDS), path::Vector{String})
    field = Symbol(path[1])
    if length(path) == 1
        if hasdata(h_in, field)
            empty!(h_in, field)
            return true
        end
    else # plain IDS
        return selective_delete!(getfield(h_in, field), path[2:end])
    end
    return false
end

function selective_delete!(@nospecialize(h_in::IDSvector), path::Vector{String})
    if isempty(h_in)
        #pass
        return false
    elseif length(path) > 1
        for k in 1:length(h_in)
            return selective_delete!(getindex(h_in, k), path[2:end])
        end
    end
end

export selective_delete!
push!(document[:Base], :selective_delete!)