module YAJL

export @yajl

using Libdl

"""
Return this variable from your callback function to cancel any further processing.
"""
const CANCEL = gensym(:yajl_cancel)

# Thrown when an invalid callback is registered.
const invalid_sig = ArgumentError("Invalid callback type signature")

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
    @eval $f(::Type{<:Context}) = C_NULL
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

    Callbacks(T::Type{<:Context}) = new(
        cb_null(T),
        cb_boolean(T),
        cb_integer(T),
        cb_double(T),
        cb_number(T),
        cb_string(T),
        cb_map_start(T),
        cb_map_key(T),
        cb_map_end(T),
        cb_array_start(T),
        cb_array_end(T),
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
    any(f -> any(m -> m.sig.types[2] === Type{T}, methods(f)), fs)

# Check that a callback's type signature is valid.
function checktypes(f::Symbol, Ts::Type...)
    # Drop the leading on_.
    f = Symbol(string(f)[4:end])
    err = invalid_sig
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
macro yajl(ex::Expr)
    # We start with an expression that should be a function definition. One of:
    # - f(...) = ...
    # - function f(...) ... end
    ex.head in (:(=), :function) ||
        throw(ArgumentError("Expression must be a function definition"))

    # If the context type for which the callback is being implemented is parametric,
    # then the function definition might have a "where" clause that changes the structure.
    # The value is either:
    # - A symbol: f(...) where T = ...
    # - An expression: f(...) where T <: IO = ...
    # - nothing: f(...) = ...
    where = ex.args[1].head === :where ? ex.args[1].args[2] : nothing

    # Next, we extract the function signature, whose position can change depending on
    # whether a where clause is present, and whether a type conversion is present.
    # It looks like:
    # - f(...)
    sig = where === nothing ? ex.args[1] : ex.args[1].args[1]
    sig.head === :(::) && (sig = sig.args[1])

    # Unmodified function name. This should be :null, :number, :string, etc.
    f = sig.args[1]
    f in CALLBACKS || throw(ArgumentError("Invalid callback name"))

    # Name of the cb_* function.
    # This function will return a function pointer to be passed to C.
    cb = Expr(:., :YAJL, QuoteNode(Symbol(:cb_, f)))

    # Rename the function to on_* to avoid any Base conflicts.
    f = sig.args[1] = Symbol(:on_, f)

    # Argument expressions.
    # There must be at least one, and each one should be typed with an optional name.
    # For example:
    # - foo::T
    # - ::T
    args = sig.args[2:end]
    isempty(args) && throw(invalid_sig)
    any(ex -> ex isa Symbol, args) &&
        throw(ArgumentError("Callback arguments must be typed"))

    # Argument types, which will be used for @cfunction.
    # Using the last expression argument gets the type for both named/unnamed arguments.
    # If all of the types were simple symbols (e.g. :Int), then Ts has eltype Symbol.
    # However, we're going to insert an Expr so we need to do a conversion.
    Ts = convert(Vector{Any}, map(ex -> ex.args[end], args))

    # We need to get the context type without any type parameters
    # to check that it actually is a Context.
    T = Ts[1]
    T_noparam = T isa Expr && T.head === :curly ? T.args[1] : T

    # Change the first argument to be a pointer, since that's what @cfunction needs.
    Ts[1] = :(Ptr{$T})

    # We'll check the context type manually, but we still need the later ones to
    # make sure that the signature is correct.
    tocheck = map(esc, Ts[2:end])

    # Now we create another function that looks identical to the user-supplied function,
    # except this one takes a Ptr{T} instead of T as the Context argument.
    # This function will load the context, call the user-supplied function,
    # then store the context back into the pointer.

    # The names don't matter, so we generate (x1, x2, ...).
    ns = map(i -> Symbol(:x, i), 1:length(Ts))

    # Start building our function. This is the signature, which looks something like:
    # - f(x1::Ptr{T} x2::T2, ...)
    delegate = Expr(:call, f, map(((n, T),) -> :($n::$T), zip(ns, Ts))...)

    # If there was a where clause in the user function, we add it here too. In that case:
    # - f(x1::Ptr{T{TT}} x2::T2, ...)::Cint where TT
    where === nothing || (delegate = Expr(:where, delegate, where))

    # Now, we build the body of the function. It has three stages:
    # - Load the context from the pointer.
    # - Run the user function on the loaded context and the other arguments. If its return
    #   value is anything but CANCEL, we return 1, otherwise 0.
    # - Store the context back to the pointer, if necessary. We only do this when both
    #   a) the context is named in the user function, b) the context is mutable.
    body = Expr(:block, :(ctx = unsafe_load(x1)),
                :(ret = $f(ctx, $(ns[2:end]...)) !== YAJL.CANCEL))

    # The signature's second argument is a typed expression with one argument
    # if it's unnamed, and two if it has a name.
    length(sig.args[2].args) == 1 ||
        push!(body.args, :(isimmutable(ctx) || unsafe_store!(x1, ctx)))

    # Lastly, just return the value we computed and wrap everything in a function.
    push!(body.args, :(return Cint(ret)))
    delegate = Expr(:function, delegate, body)

    # Create the callback function, which will create a C function pointer to the delegate.
    cbfun = Expr(:call, cb, :(::Type{$T}))
    where === nothing || (cbfun = Expr(:where, cbfun, where))
    cbfun = Expr(:(=), cbfun, :(@cfunction $f Cint ($(Ts...),)))

    # Warn if a useless or destructive callback is being added.
    # For more info, see the note in the docstring.
    warn1 = if f === :on_number
        quote
            YAJL.hasmethod($T, YAJL.cb_integer, YAJL.cb_double) &&
                @warn "Implementing number callback for $($T) disables both integer and double callbacks"
        end
    end
    warn2 = if f in (:on_integer, :on_double)
        quote
            YAJL.hasmethod($T, YAJL.cb_number) &&
                @warn "Implementing integer or double callback for $($T) has no effect because number callback is already implemented"
        end
    end

    quote
        $(esc(T_noparam)) <: Context || throw(invalid_sig)
        checktypes($(QuoteNode(f)), $(tocheck...))
        $(esc(warn1))
        $(esc(warn2))
        $(esc(ex))
        $(esc(delegate))
        $(esc(cbfun))
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
    cbs = Callbacks(T)
    handle = ccall(yajl[:alloc], Ptr{Cvoid}, (Ref{Callbacks}, Ptr{Cvoid}, Ref{T}),
                   cbs, C_NULL, ctx)

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
