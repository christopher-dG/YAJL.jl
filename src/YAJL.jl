module YAJL

export @yajl

using Libdl


"""
Return this variable from your callback function to cancel any further processing.
"""
const CANCEL = gensym(:yajl_cancel)

"""
Base type for YAJL contexts.
To implement a custom `Context`'s behaviour, see [`@yajl`](@ref) and [`collect`](@ref).
For a full example, see `minifier.jl`.
"""
abstract type Context end

# YAJL callback types.
const CALLBACKS = (:null, :boolean, :integer, :double, :number, :string, :map_start,
                   :map_key, :map_end, :array_start, :array_end)

# Default callbacks.
for s in [:null, :boolean, :integer, :double, :number, :string, :map_start, :map_key,
          :map_end, :array_start, :array_end]
    f = Symbol(:cb_, s)
    @eval $f(::Context) = C_NULL
end

"""
    collect(ctx::Context)

Override this function for your custom [`Context`](@ref) to specify what is returned from [`run`](@ref).
By default, `ctx` itself is returned.
"""
collect(ctx::Context) = ctx

struct Callbacks
    null::Ptr{Cvoid}
    boolean::Ptr{Cvoid}
    integer::Ptr{Cvoid}
    double::Ptr{Cvoid}
    number::Ptr{Cvoid}
    string::Ptr{Cvoid}
    map_start::Ptr{Cvoid}
    map_key::Ptr{Cvoid}
    map_end::Ptr{Cvoid}
    array_start::Ptr{Cvoid}
    array_end::Ptr{Cvoid}

    Callbacks(ctx::Context) = new(
        cb_null(ctx),
        cb_boolean(ctx),
        cb_integer(ctx),
        cb_double(ctx),
        cb_number(ctx),
        cb_string(ctx),
        cb_map_start(ctx),
        cb_map_key(ctx),
        cb_map_end(ctx),
        cb_array_start(ctx),
        cb_array_end(ctx),
    )
end

# Parse options.
const ALLOW_COMMENTS = 0x01
const DONT_VALIDATE_STRINGS = 0x02
const ALLOW_TRAILING_GARBAGE = 0x04
const ALLOW_MULTIPLE_VALUES = 0x08
const ALLOW_PARTIAL_VALUES = 0x10
const OPTIONS = [
    ALLOW_COMMENTS, DONT_VALIDATE_STRINGS, ALLOW_TRAILING_GARBAGE, ALLOW_MULTIPLE_VALUES,
    ALLOW_PARTIAL_VALUES,
]

# Check if a context type has defined a function.
hasmethod(T::Type{<:Context}, fs::Function...) =
    any(f -> any(m -> m.sig.types[2] === T, methods(f)), fs)

# Check that a callback's type signature is valid.
function checktypes(f::Symbol, ::Type{Ptr{C}}, Ts::Type...) where C
    # Drop the leading on_.
    f = Symbol(string(f)[4:end])
    err = ArgumentError("Invalid callback type signature")

    C <: Context || throw(err)
    if f in (:boolean, :integer)
        length(Ts) == 1 && Ts[1] <: Integer || throw(err)
    elseif f === :double
        length(Ts) == 1 && Ts[1] <: AbstractFloat || throw(err)
    elseif f in (:number, :string, :map_key)
        length(Ts) == 2 && Ts[1] in (Ptr{UInt8}, Cstring) && Ts[2] <: Integer || throw(err)
    else
        isempty(Ts) || throw(err)
    end
end

"""
Register a callback for a specific data type.
Inside the callback function, the special value [`CANCEL`](@ref) can be returned to stop processing.

The callbacks to be overridden are as follows:

- `null(ctx::T)`: Called on `null` values.
- `boolean(ctx::T, v::Bool)`: `Called on boolean values.
- `integer(ctx::T, v::Int)`: Called on integer values (see note below).
- `double(ctx::T, v::Float64)`: Called on float values (see note below).
- `number(ctx::T, v::Ptr{UInt8}, len::Int)`: Called on numeric values (see note below).
- `string(ctx::T, v::Ptr{UInt8}, len::Int)`: Called on string values.
- `map_start(ctx::T)`: Called when an object begins (`{`).
- `map_key(ctx::T, v::Ptr{UInt8}, len::Int)`: Called on object keys.
- `map_end(ctx::T)`: Called when an object ends (`}`).
- `array_start(ctx::T)`: Called when an array begins (`[`).
- `array_end(ctx::T)`: Called when an array ends (`]`).

For string arguments which appear as `Ptr{UInt8}`, `Cstring` can also be used.
However, `Ptr{UInt8}` is usually better if you want to use `unsafe_string(v, len)`.

!!! note
    To handle numbers, implement either `number` or both `integer` and `double`.
    Usually, `number` is a better choice because `integer` and `double have limited precision.
    See [here](https://lloyd.github.io/yajl/yajl-2.1.0/structyajl__callbacks.html) for more details.

!!! warning
    If your [`Context`](@ref) is a parametric type, it must appear non-parameterized in the function definition.
    This means that your callback functions cannot dispatch on the context's type parameter.

For a full example, see `minifier.jl`.
"""
macro yajl(ex)

    # Unmodified function name.
    f = ex.args[1].args[1]

    # Ensure that it's a valid callback name.
    f in CALLBACKS || throw(ArgumentError("Invalid callback name"))

    # Name of the cb_* function.
    cb = Expr(:., :YAJL, QuoteNode(Symbol(:cb_, f)))

    # Rename the function to on_* to avoid any Base conflicts.
    f = ex.args[1].args[1] = Symbol(:on_, f)

    # Argument types for @cfunction.
    Ts = map(ex.args[1].args[2:end]) do ex
        ex isa Symbol && throw(ArgumentError("Callback arguments must be typed"))
        ex.args[end]
    end
    Ts = convert(Vector{Any}, Ts)
    isempty(Ts) && throw(ArgumentError("Invalid callback type signature"))
    T = Ts[1]
    Ts[1] = :(Ptr{$T})
    Ts_esc = map(esc, Ts)

    # Create another function that takes a pointer.
    ns = map(i -> Symbol(:x, i), 1:length(Ts))
    args = map(((n, T),) -> :($n::$T), zip(ns, Ts))
    load, store = if length(ex.args[1].args[2].args) > 1
        :(ctx = unsafe_load(x1)), :(isimmutable(ctx) || unsafe_store!(x1, ctx))
    else
        :(ctx = Ptr{$T}(0)), :()
    end

    delegate = quote
        function $f($(args...))::Cint
            $load
            ret = $f(ctx, $(ns[2:end]...)) !== YAJL.CANCEL
            $store
            return ret
        end
    end

    # Warn if a useless or destructive callback is being added.
    warn1 = if f === :on_number
        quote
            YAJL.hasmethod($(esc(T)), cb_integer, cb_double) &&
                @warn "Implementing number callback for $($T) disables both integer and double callbacks"
        end
    end
    warn2 = if f in (:on_integer, :on_double)
        quote
            YAJL.hasmethod($(esc(T)), cb_number) &&
                @warn "Implementing integer or double callback for $($T) has no effect because number callback is already implemented"
        end
    end

    quote
        checktypes($(QuoteNode(f)), ($(Ts_esc...),)...)
        $warn1
        $warn2
        $(esc(ex))
        $(esc(delegate))
        $(esc(cb))(::$(esc(T))) = @cfunction $f Cint ($(Ts_esc...),)
    end
end

const ST_OK = 0
const ST_CLIENT_CANCELLED = 1
const ST_ERROR = 2

# A YAJL parser error.
struct ParseError <: Exception
    reason::String
end

# Check the parser status and throw an exception if there's an error.
function checkstatus(handle::Ptr{Cvoid}, status::Cint, text::Vector{UInt8}, len::Int)
    return if status == ST_OK
        true
    elseif status == ST_CLIENT_CANCELLED
        false
    elseif status == ST_ERROR
        err = ccall(yajl[:get_error], Cstring, (Ptr{Cvoid}, Cint, Ptr{Cuchar}, Csize_t),
                    handle, 1, text, len)
        reason = unsafe_string(err)
        ccall(yajl[:free_error], Cvoid, (Ptr{Cvoid}, Cstring), handle, err)
        throw(ParseError(reason))
    else
        @warn "yajl_parse returned unknown status: $status"
        true
    end
end

"""
    run(io::IO, ctx::Context; chunk::Integer=2^16, options::Integer=0x0)

Parse the JSON data from `io` and process it with `ctx`'s callbacks.
The return value is determined by the implementation of [`collect`](@ref) for `ctx`.

## Keywords
- `chunk::Integer=2^16`: Number of bytes to read from `io` at a time.
- `options::Integer=0x0`: YAJL parser options, ORed together.
"""
function run(io::IO, ctx::T; chunk::Integer=2^16, options::Integer=0x0) where T <: Context
    handle = ccall(yajl[:alloc], Ptr{Cvoid}, (Ptr{Callbacks}, Ptr{Cvoid}, Ptr{T}),
                   Ref(Callbacks(ctx)), C_NULL, Ref(ctx))

    for o in OPTIONS
        if options & o == o
            ccall(yajl[:config], Cint, (Ptr{Cvoid}, Cuint), handle, o)
        end
    end

    cancelled = false
    text = Vector{UInt8}(undef, chunk)
    while !eof(io)
        n = readbytes!(io, text)
        status = ccall(yajl[:parse], Cint, (Ptr{Cvoid}, Ptr{Cuchar}, Csize_t),
                       handle, text, n)
        if !checkstatus(handle, status, text, n)
            cancelled = true
            break
        end
    end

    if !cancelled
        status = ccall(yajl[:complete_parse], Cint, (Ptr{Cvoid},), handle)
        checkstatus(handle, status, UInt8[], 0)
    end

    ccall(yajl[:free], Cvoid, (Ptr{Cvoid},), handle)

    return collect(ctx)
end

# Container for function pointers.
const yajl = Dict{Symbol, Ptr{Cvoid}}()

const depsfile = joinpath(dirname(@__DIR__), "deps", "deps.jl")
isfile(depsfile) ? include(depsfile) : error("""Run Pkg.build("YAJL")""")

# Load functions at runtime.
function __init__()
    check_deps()
    lib = Libdl.dlopen(libyajl)
    for f in [:alloc, :complete_parse, :config, :free, :free_error, :get_error, :parse]
        yajl[f] = Libdl.dlsym(lib, Symbol(:yajl_, f))
    end
end

include("minifier.jl")

end
