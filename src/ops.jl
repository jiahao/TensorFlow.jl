import Base: log, exp, +, -, *, /, .*, .+, ./, .-, ^, .^

const name_idx = Ref{Int}(1)

function capitalize(s)
    string(uppercase(s[1]), s[2:end])
end

capitalize(s::Symbol) = capitalize(string(s))

function get_name(name="")
    if length(name) > 0
        return name
    else
        name = "node$(name_idx[])"
        name_idx[] += 1
        return name
    end
end

function placeholder(dtype; name="")
    name = get_name(name)
    desc = NodeDescription(get_def_graph(), "Placeholder", name)
    desc["dtype"] = dtype
    node = Node(desc)
end

function constant(tensor; name="")
    name = get_name(name)
    desc = NodeDescription(get_def_graph(), "Const", name)
    tensor = Tensor(tensor)
    desc["dtype"] = eltype(tensor)
    desc["value"] = tensor
    node = Node(desc)
end

Base.convert(::Type{Node}, x::Number) = constant(x)
Base.convert{T<:Number}(::Type{Node}, x::Array{T}) = constant(x)

function tf_promote(t, x::Number)
    return Node(eltype(t)(x))
end

tf_promote(t, x) = Node(x)

for (bin_op, jl_func_name, tf_func_name) in [
    (:+, :add, "Add"),
    (:-, :sub, "Sub"),
    (:(.*), :mul, "Mul"),
    (:*, :matmul, "MatMul"),
    (:/, :div, "Div"),
    (:^, :pow, "Pow")]
    @eval function $jl_func_name(n1::AbstractNode, n2::AbstractNode; name="")
        n1 = Node(n1)
        n2 = Node(n2)
        name = get_name(name)
        desc = NodeDescription(get_def_graph(), $tf_func_name, name)
        add_input(desc, Port(Node(n1), 1))
        add_input(desc, Port(Node(n2), 1))
        Node(desc)
    end

    @eval $bin_op(n1::AbstractNode, n2::AbstractNode) = $jl_func_name(n1, n2)
    @eval $bin_op(n1::AbstractNode, n2) = $jl_func_name(n1, tf_promote(n1, n2))
    @eval $bin_op(n1, n2::AbstractNode) = $jl_func_name(tf_promote(n2, n1), n2)
end

*(x::Number, n::AbstractNode) = x.*n  # For supporting notation like `2x`
^(n::AbstractNode, x::Int) = invoke(^, (AbstractNode, Any), n, x)
.^(n::AbstractNode, x::Number) = n^x

for (jl_func_name, tf_func_name) in [
    (:log, "Log"),
    (:exp, "Exp"),
    (:neg, "Neg"),
    (:ceil, "Ceil"),
    (:floor, "Floor"),
    (:sqrt, "Sqrt"),
    (:square, "Square"),
    (:cos, "Cos"),
    (:sin, "Sin"),
    (:tan, "Tan"),
    (:transpose, "Transpose")]
    @eval function $jl_func_name(n::AbstractNode; name="")
        n = Node(n)
        name = get_name(name)
        desc = NodeDescription(get_def_graph(), $tf_func_name, name)
        add_input(desc, Port(n, 1))
        Node(desc)
    end
end

-(n::Node) = neg(n)

# Reductions

for reduction in [:sum, :prod, :min, :max, :all, :any, :mean]
    @eval function $(Symbol("reduce_", reduction))(n::AbstractNode; reduction_indices=nothing, keep_dims=false, name="")
        if reduction_indices == nothing
            n = Node(n)
            name = get_name(name)
            range_start = constant(Int32(0))
            range_delta = constant(Int32(1))
            desc = NodeDescription(get_def_graph(), "Rank", "$name/rank")
            add_input(desc, n)
            rank = Node(desc)
            desc = NodeDescription(get_def_graph(), "Range", "$name/range")
            add_input(desc, range_start)
            add_input(desc, rank)
            add_input(desc, range_delta)
            range = Node(desc)
            desc = NodeDescription(get_def_graph(), $(capitalize(reduction)), name)
            add_input(desc, n)
            add_input(desc, range)
            Node(desc)
        else
            if isa(reduction_indices, Number)
                reduction_indices = [reduction_indices]
            end
            reduction_indices = map(Int32, reduction_indices)
            desc = NodeDescription(get_def_graph(), $(capitalize(reduction)), get_name(name))
            add_input(desc, Node(n))
            add_input(desc, Node(reduction_indices))
            desc["keep_dims"] = keep_dims
            Node(desc)
        end
    end
end

function Base.reshape(n::Node, dims; name="")
    dims = Int32[dims...]
    desc = NodeDescription(get_def_graph(), "Reshape",  get_name(name))
    add_input(desc, n)
    add_input(desc, Node(dims))
    Node(desc)
end

function Base.fill(n::Node, dims::Node; name="")
    desc = NodeDescription(get_def_graph(), "Fill", get_name(name))
    add_input(desc, dims)
    add_input(desc, n)
    Node(desc)
end

function Base.fill(::Type{Node}, n, dims; name="")
    fill(Node(n), Node(dims); name=name)
end

convert_number(t, n) = n
convert_number(t, x::Number) =  t(x)

function Base.linspace(::Type{Node}, start, stop, num; name="")
    desc = NodeDescription(get_def_graph(), "LinSpace", get_name(name))
    add_input(desc, Node(convert_number(Float32, start)))
    add_input(desc, Node(convert_number(Float32, stop)))
    add_input(desc, Node(convert_number(Int32, num)))
    Node(desc)
end

function Base.range(::Type{Node}, start; limit=nothing, delta=1, name="")
    if limit == nothing
        limit = start
        start = 0
    end
    desc = NodeDescription(get_def_graph(), "Range", get_name(name))
    add_input(desc, start)
    add_input(desc, limit)
    add_input(desc, delta)
    Node(desc)
end

function Base.rank(n::AbstractNode; name="")
    desc = NodeDescription(get_def_graph(), "Rank", get_name(name))
    add_input(desc, Node(n))
    Node(desc)
end

function Base.size(n::AbstractNode; name="")
    desc = NodeDescription(get_def_graph(), "Size", get_name(name))
    add_input(desc, Node(n))
    Node(desc)
end

Base.length(::Type{Node}, n::AbstractNode; name="") = size(n, name)

function Base.slice(n::AbstractNode, begin_, size_; name="")
    desc = NodeDescription(get_def_graph(), "Slice", get_name(name))
    add_input(desc, Node(n))
    add_input(desc, Node(begin_))
    add_input(desc, Node(size_))
    Node(desc)
end

function concat(dim, values; name="")
    desc = NodeDescription(get_def_graph(), "Concat", get_name(name))
    add_input(desc, Node(convert_number(Int32, dim)))
    add_input(desc, [Port(_, 1) for _ in values])
    desc["N"] = length(values)
    Node(desc)
end

Base.cat(::Type{Node}, dim, values) = concat(dim, values)

include("nn.jl")
include("image.jl")
