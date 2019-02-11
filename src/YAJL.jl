module YAJL

using Libdl

"""
Base type for YAJL contexts.
To implement a custom `Context`'s behaviour, see [`@callback`](@ref) and [`complete`](@ref).
For a full example, see `minifier.jl`.
"""
abstract type Context end

# Default callbacks.
for s in [:null, :boolean, :integer, :double, :number, :string, :map_start, :map_key,
          :map_end, :array_start, :array_end]
    f = Symbol(:cb_, s)
    @eval $f(::Context) = C_NULL
end

"""
    complete(ctx::Context)

Override this function for your custom [`Context`](@ref) to specify what is returned from [`run`](@ref).
"""
complete(ctx::Context) = ctx

struct Callbacks
    null::Ptr{Cvoid}
    boolean::Ptr{Cvoid}
    integer::Ptr{Cvoid}
    double::Ptr{Cvoid}
    number::Ptr{Cvoid}
    string::Ptr{Cvoid}
    start_map::Ptr{Cvoid}
    map_key::Ptr{Cvoid}
    end_map::Ptr{Cvoid}
    start_array::Ptr{Cvoid}
    end_array::Ptr{Cvoid}

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

"""
Register a callback for a specific data type.
Callback functions must return `true` or a non-zero integer, otherwise a parsing error is thrown.

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
However, `Ptr{UInt8}` is usually better if you want to use `unsafe_string`.

!!! note
    To handle numbers, implement either `number` or both `integer` and `double`.
    Usually, `number` is a better choice because `integer` and `double have limited precision.
    See [here](https://lloyd.github.io/yajl/yajl-2.1.0/structyajl__callbacks.html) for more details.

For a full example, see `minifier.jl`.
"""
macro callback(ex)
    # Ensure that the function returns a Cint.
    if ex.args[1].args[1] isa Symbol
        ex.args[1] = Expr(:(::), ex.args[1], :Cint)
    else
        ex.args[1].args[2] = :Cint
    end

    # First function argument: Context subtype.
    T = ex.args[1].args[1].args[2].args[2]

    # Name of the cb_* function.
    cb = Symbol(:cb_, ex.args[1].args[1].args[1])

    # Rename the function to on_* to avoid any Base conflicts.
    f = ex.args[1].args[1].args[1] = Symbol(:on_, ex.args[1].args[1].args[1])

    # Argument types for @cfunction.
    Ts = map(ex -> esc(ex.args[2]), ex.args[1].args[1].args[2:end])
    Ts[1] = :(Ref($T))

    quote
        $(esc(ex))
        $(esc(cb))(::$(esc(T))) = @cfunction($f, Cint, ($(Ts...),))
    end
end

@enum Status OK CLIENT_CANCELLED ERROR UNKNOWN

# A YAJL parser error.
struct ParseError <: Exception
    status::Status
    reason::String
end

# Check the parser status and throw an exception if there's an error.
function checkstatus(handle::Ptr{Cvoid}, status::Cint, text::Vector{UInt8})
    if status == Cint(OK)
        return
    elseif status == Cint(CLIENT_CANCELLED)
        throw(ParseError(CLIENT_CANCELLED, ""))
    elseif status == Cint(ERROR)
        err = ccall(yajl[:get_error], Cstring, (Ptr{Cvoid}, Cint, Ptr{Cuchar}, Csize_t),
                    handle, 1, text, length(text))
        reason = unsafe_string(err)
        ccall(yajl[:free_error], Cvoid, (Ptr{Cvoid}, Cstring), handle, err)
        throw(ParseError(ERROR, reason))
    elseif status == Cint(UNKNOWN)
        throw(ParseError(status, ""))
    end
end

"""
    run(ctx::Context, io::IO; chunk::Integer=2^16, options::Integer=0x0)

Parse the JSON data from `io` and process it with `ctx`'s callbacks.
The return value is determined by the implementation of [`complete`](@ref) for `ctx`.
By default, `ctx` itself is returned.

# Keywords
- `chunk::Integer=2^16`: Number of bytes to read from `io` at a time.
- `options::Integer=0x0`: YAJL parser options, ORed together.
"""
function run(ctx::T, io::IO; chunk::Integer=2^16, options::Integer=0x0) where T <: Context
    handle = ccall(yajl[:alloc], Ptr{Cvoid}, (Ptr{Callbacks}, Ptr{Cvoid}, Ptr{T}),
                   Ref(Callbacks(ctx)), C_NULL, Ref(ctx))

    for o in OPTIONS
        if options & o == o
            ccall(yajl[:config], Cint, (Ptr{Cvoid}, Cuint), handle, o)
        end
    end

    while bytesavailable(io) > 0
        text = read(io, chunk)
        status = ccall(yajl[:parse], Cint, (Ptr{Cvoid}, Ptr{Cuchar}, Csize_t),
                       handle, text, length(text))
        checkstatus(handle, status, text)
    end

    status = ccall(yajl[:complete_parse], Cint, (Ptr{Cvoid},), handle)
    checkstatus(handle, status, UInt8[])

    ccall(yajl[:free], Cvoid, (Ptr{Cvoid},), handle)

    return complete(ctx)
end

# Container for function pointers.
const yajl = Dict{Symbol, Ptr{Cvoid}}()

# Load functions at runtime.
function __init__()
    lib = Libdl.dlopen(:libyajl)
    for f in [:alloc, :complete_parse, :config, :free, :free_error, :get_error, :parse]
        yajl[f] = Libdl.dlsym(lib, Symbol(:yajl_, f))
    end
end

include("minifier.jl")

end
