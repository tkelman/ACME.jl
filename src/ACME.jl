module ACME

export Circuit, add!, connect!

type Element
  mv :: SparseMatrixCSC{Number,Int}
  mi :: SparseMatrixCSC{Number,Int}
  mx :: SparseMatrixCSC{Number,Int}
  mxd :: SparseMatrixCSC{Number,Int}
  mq :: SparseMatrixCSC{Number,Int}
  mu :: SparseMatrixCSC{Number,Int}
  u0 :: SparseMatrixCSC{Number,Int}
  pv :: SparseMatrixCSC{Number,Int}
  pi :: SparseMatrixCSC{Number,Int}
  px :: SparseMatrixCSC{Number,Int}
  pxd :: SparseMatrixCSC{Number,Int}
  pq :: SparseMatrixCSC{Number,Int}
  nonlinear_eq :: Expr
  pins :: Dict{Symbol, Vector{(Int, Int)}}

  function Element(;args...)
    sizes = (Symbol=>Int)[:n0 => 1]

    function update_sizes(mat, syms)
      for (sym, s) in zip(syms, size(mat))
        if !haskey(sizes, sym)
          sizes[sym] = s
        elseif sizes[sym] ≠ s
          error("Inconsistent sizes for ", sym)
        end
      end
    end

    function make_pin_dict(syms)
      dict = (Symbol=>Vector{(Int, Int)})[]
      for i in 1:length(syms)
        branch = div(i+1, 2)
        polarity = 2mod(i, 2) - 1
        push!(get!(dict, symbol(syms[i]), []), (branch, polarity))
      end
      dict
    end
    make_pin_dict(dict::Dict) = dict

    const mat_dims = [ :mv => (:nl,:nb), :mi => (:nl,:nb), :mx => (:nl,:nx),
                       :mxd => (:nl,:nx), :mq => (:nl,:nq), :mu => (:nl,:nu),
                       :u0 => (:nl, :n0),
                       :pv => (:ny,:nb), :pi => (:ny,:nb), :px => (:ny,:nx),
                       :pxd => (:ny,:nx), :pq => (:ny,:nq) ]

    elem = new()
    for (key, val) in args
      if haskey(mat_dims, key)
        val = sparse([val])
        update_sizes (val, mat_dims[key])
      elseif key == :pins
        val = make_pin_dict (val)
      end
      elem.(key) = val
    end
    for (m, ns) in mat_dims
      if !isdefined(elem, m)
        elem.(m) = spzeros(Int, get(sizes, ns[1], 0), get(sizes, ns[2], 0))
      end
    end
    if !isdefined(elem, :nonlinear_eq)
      elem.nonlinear_eq = Expr(:block)
    end
    if !isdefined(elem, :pins)
      elem.pins = make_pin_dict(map(string,1:2nb(elem)))
    end
    elem
  end
end

for (n,m) in [:nb => :mv, :nx => :mx, :nq => :mq, :nu => :mu]
  @eval ($n)(e::Element) = size(e.$m)[2]
end
nl(e::Element) = size(e.mv)[1]
ny(e::Element) = size(e.pv)[1]
nn(e::Element) = nb(e) + nx(e) + nq(e) - nl(e)

# a Pin combines an element with a branch/polarity list
typealias Pin (Element, Vector{(Int,Int)})

# allow elem[:pin] notation to get an elements pin
getindex(e::Element, p::Symbol) = (e, e.pins[p])
getindex(e::Element, p::String) = getindex(e, symbol(p))
getindex(e::Element, p::Int) = getindex(e, string(p))

include("elements.jl")

typealias Net Vector{(Int,Int)} # each net is a list of branch/polarity pairs

type Circuit
    elements :: Vector{Element}
    nets :: Vector{Net}
    net_names :: Dict{Symbol, Net}
    Circuit() = new([], [], Dict{Symbol, Net}())
end

for n in [:nb, :nx, :nq, :nu, :nl, :ny, :nn]
    @eval ($n)(c::Circuit) = sum([$n(elem) for elem in c.elements])
end

for mat in [:mv, :mi, :mx, :mxd, :mq, :mu, :pv, :pi, :px, :pxd, :pq]
    @eval ($mat)(c::Circuit) = blkdiag([elem.$mat for elem in c.elements]...)
end

u0(c::Circuit) = vcat([elem.u0 for elem in c.elements]...)

function incidence(c::Circuit)
    i = sizehint(Int[], 2nb(c))
    j = sizehint(Int[], 2nb(c))
    v = sizehint(Int[], 2nb(c))
    for (row, pins) in enumerate(c.nets), (branch, polarity) in pins
        push!(i, row)
        push!(j, branch)
        push!(v, polarity)
    end
    # ensure zeros due to short-circuited branches are removed, hence the
    # additional sparse(findnz(...))
    sparse(findnz(sparse(i,j,v))..., length(c.nets), nb(c))
end

function nonlinear_eq(c::Circuit)
    # construct a block expression containing all element's expressions after
    # offsetting their indexes into q, J and res

    row_offset = 0
    col_offset = 0
    nl_expr = Expr(:block)
    for elem in c.elements
        index_offsets = { :q => (col_offset,),
                          :J => (row_offset, col_offset),
                          :res => (row_offset,) }

        function offset_indexes(expr::Expr)
            ret = Expr(expr.head)
            ret.typ = expr.typ
            if expr.head == :ref && haskey(index_offsets, expr.args[1])
                push!(ret.args, expr.args[1])
                offsets = index_offsets[expr.args[1]]
                length(expr.args) == length(offsets) + 1 ||
                    throw(ArgumentError(string(expr.args[1], " must be indexed with exactly ", length(offsets), " index(es)")))
                for i in 1:length(offsets)
                    push!(ret.args,
                          :($(offsets[i]) + $(offset_indexes(expr.args[i+1]))))
                end
            else
                push!(ret.args, map(offset_indexes, expr.args)...)
            end
            ret
        end

        function offset_indexes(s::Symbol)
            haskey(index_offsets, s) && throw(ArgumentError(string(s, " used without indexing expression")))
            s
        end

        offset_indexes(x::Any) = x

        # wrap into a let to keep variables local
        push!(nl_expr.args, :( let; $(offset_indexes(elem.nonlinear_eq)) end))

        row_offset += nn(elem)
        col_offset += nq(elem)
    end
    nl_expr
end

function add!(c::Circuit, elem::Element)
    elem ∈ c.elements && return
    b_offset = nb(c)
    push!(c.elements, elem)
    for branch_pols in values(elem.pins)
        push!(c.nets, [(b_offset + b, pol) for (b, pol) in branch_pols])
    end
    nothing
end

add!(c::Circuit, elems::Element...) = for elem in es add!(c, elem) end

function branch_offset(c::Circuit, elem::Element)
    offset = 0
    for el in c.elements
        el == elem && return offset
        offset += nb(el)
    end
    throw(ArgumentError("Element not found in circuit"))
end

function netfor!(c::Circuit, p::Pin)
    element = p[1]
    add!(c, element)
    b_offset = branch_offset(c, element)
    local net
    for (branch, pol) in p[2], net in c.nets
        (branch + b_offset, pol) ∈ net && break
    end
    @assert isdefined(net)
    net
end

function netfor!(c::Circuit, name::Symbol)
    haskey(c.net_names, name) || push!(c.nets, get!(c.net_names, name, []))
    c.net_names[name]
end

function connect!(c::Circuit, pins::Union(Pin,Symbol)...)
    nets = unique([netfor!(c, pin) for pin in pins])
    for net in nets[2:end]
        push!(nets[1], net...)
        deleteat!(c.nets, findfirst(c.nets, net))
        for (name, named_net) in c.net_names
            if named_net == net
                c.net_names[name] = nets[1]
            end
        end
    end
end

function topomat!{T<:Integer}(incidence::SparseMatrixCSC{T})
    @assert all(abs(nonzeros(incidence)) .== 1)
    @assert all(sum(incidence, 1) .== 0)

    t = falses(size(incidence)[2]);

    row = 1;
    for col = 1:size(incidence)[2]
        rows = filter(r -> r ≥ row, find(incidence[:,col]))
        @assert length(rows) ≤ 2

        isempty(rows) && continue
        t[col] = true;

        if rows[1] ≠ row
            incidence[[rows[1], row],:] = incidence[[row, rows[1]],:]
        end
        if length(rows) == 2
            @assert incidence[row, col] + incidence[rows[2], col] == 0
            incidence[rows[2],:] = incidence[rows[2],:] + incidence[row,:]
        end
        if incidence[row, col] < 0
            cols = find(incidence[row,:])
            incidence[row,cols] = -incidence[row,cols]
        end
        rows = find(incidence[1:row-1,col] .== 1)
        incidence[rows,:] = broadcast(-, incidence[rows, :], incidence[row,:])
        rows = find(incidence[1:row-1,col] .== -1)
        incidence[rows,:] = broadcast(+, incidence[rows, :], incidence[row,:])
        row += 1
    end

    ti = incidence[1:row-1, :]

    dl = ti[:, ~t]
    tv = spzeros(T,size(dl)[2], size(incidence)[2])
    tv[:,find(t)] = -dl.'
    tv[:,find(~t)] = speye(T,size(dl)[2])

    tv, ti
end

topomat{T<:Integer}(incidence::SparseMatrixCSC{T}) = topomat!(copy(incidence))
topomat(c::Circuit) = topomat!(incidence(c))

end # module