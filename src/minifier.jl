@enum MinifyState begin
    MINIFY_INIT
    MINIFY_MAP_KEY
    MINIFY_MAP_KEY_FIRST
    MINIFY_MAP_VAL
    MINIFY_ARRAY
    MINIFY_ARRAY_FIRST
end

const NULL = Vector{UInt8}("null")
const COLON = UInt8(':')
const COMMA = UInt8(',')
const QUOTE = UInt8('"')
const OPEN_BRACE = UInt8('{')
const CLOSE_BRACE = UInt8('}')
const OPEN_BRACKET = UInt8('[')
const CLOSE_BRACKET = UInt8(']')

"""
    Minifier(io::IO=stdout) -> Minifier

Removes all unecessary whitespace from JSON.

# Example
```jldoctest
julia> String(take!(YAJL.run(YAJL.Minifier(IOBuffer()), IOBuffer("{    }"))))
"{}"
```
"""
struct Minifier{T<:IO} <: Context
    io::T
    state::Vector{MinifyState}

    Minifier(io::T=stdout) where T <: IO = new{T}(io, [MINIFY_INIT])
end

complete(ctx::Minifier) = ctx.io

write(ctx::Minifier, v::Ptr{UInt8}, len::Int) = unsafe_write(ctx.io, v, len)
write(ctx::Minifier, v::Vector{UInt8}, ::Int=-1) = Base.write(ctx.io, v)
write(ctx::Minifier, v::UInt8, ::Int=-1) = Base.write(ctx.io, v)

# Yuck.
function addval(ctx::Minifier, v, len::Int=-1; string::Bool=false)
    state = last(ctx.state)
    if state === MINIFY_INIT
        string && write(ctx, QUOTE)
        write(ctx, v, len)
        string && write(ctx, QUOTE)
    elseif state === MINIFY_MAP_KEY
        write(ctx, [COMMA, QUOTE])
        write(ctx, v, len)
        write(ctx, [QUOTE, COLON])
        ctx.state[lastindex(ctx.state)] = MINIFY_MAP_VAL
    elseif state === MINIFY_MAP_KEY_FIRST
        write(ctx, QUOTE)
        write(ctx, v, len)
        write(ctx, [QUOTE, COLON])
        ctx.state[lastindex(ctx.state)] = MINIFY_MAP_VAL
    elseif state === MINIFY_MAP_VAL
        string && write(ctx, QUOTE)
        write(ctx, v, len)
        string && write(ctx, QUOTE)
        ctx.state[lastindex(ctx.state)] = MINIFY_MAP_KEY
    elseif state === MINIFY_ARRAY
        write(ctx, COMMA)
        string && write(ctx, QUOTE)
        write(ctx, v, len)
        string && write(ctx, QUOTE)
    elseif state === MINIFY_ARRAY_FIRST
        string && write(ctx, QUOTE)
        write(ctx, v, len)
        string && write(ctx, QUOTE)
        ctx.state[lastindex(ctx.state)] = MINIFY_ARRAY
    end
    return 1
end

@callback null(ctx::Minifier) = addval(ctx, NULL)
@callback boolean(ctx::Minifier, v::Bool) = addval(ctx, v)
@callback number(ctx::Minifier, v::Ptr{UInt8}, len::Int) = addval(ctx, v, len)
@callback string(ctx::Minifier, v::Ptr{UInt8}, len::Int) = addval(ctx, v, len; string=true)
@callback function map_start(ctx::Minifier)
    last(ctx.state) in (MINIFY_ARRAY, MINIFY_MAP_KEY) && write(ctx, COMMA)
    write(ctx, OPEN_BRACE)
    push!(ctx.state, MINIFY_MAP_KEY_FIRST)
    return 1
end
@callback map_key(ctx::Minifier, v::Ptr{UInt8}, len::Int) = addval(ctx, v, len)
@callback function map_end(ctx::Minifier)
    write(ctx, CLOSE_BRACE)
    pop!(ctx.state)

    state = last(ctx.state)
    if state === MINIFY_MAP_KEY_FIRST
        ctx.state[lastindex(ctx.state)] = MINIFY_MAP_KEY
    elseif state === MINIFY_ARRAY_FIRST
        ctx.state[lastindex(ctx.state)] = MINIFY_ARRAY
    end

    return 1
end
@callback function array_start(ctx::Minifier)
    last(ctx.state) in (MINIFY_ARRAY, MINIFY_MAP_KEY) && write(ctx, COMMA)
    write(ctx, OPEN_BRACKET)
    push!(ctx.state, MINIFY_ARRAY_FIRST)
    return 1
end
@callback function array_end(ctx::Minifier)
    write(ctx, CLOSE_BRACKET)
    pop!(ctx.state)

    state = last(ctx.state)
    if state === MINIFY_MAP_KEY_FIRST
        ctx.state[lastindex(ctx.state)] = MINIFY_MAP_KEY
    elseif state === MINIFY_ARRAY_FIRST
        ctx.state[lastindex(ctx.state)] = MINIFY_ARRAY
    end

    return 1
end
