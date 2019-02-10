module YAJL

using Libdl

@enum Status OK CLIENT_CANCELLED ERROR UNKNOWN

struct YAJLError <: Exception
    status::Status
    reason::String
end

struct Context end

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
end

const yajl = Dict{Symbol, Ptr{Cvoid}}()
const callbacks = Ref{Callbacks}()

const ALLOW_COMMENTS = 0x01
const DONT_VALIDATE_STRINGS = 0x02
const ALLOW_TRAILING_GARBAGE = 0x04
const ALLOW_MULTIPLE_VALUES = 0x08
const ALLOW_PARTIAL_VALUES = 0x10
const OPTIONS = [
    ALLOW_COMMENTS, DONT_VALIDATE_STRINGS, ALLOW_TRAILING_GARBAGE, ALLOW_MULTIPLE_VALUES,
    ALLOW_PARTIAL_VALUES,
]

function on_null(ctx::Context)::Cint
    return 1
end

function on_boolean(ctx::Context, v::Cint)::Cint
    return 1
end

function on_number(ctx::Context, v::Cstring, len::Csize_t)::Cint
    return 1
end

function on_string(ctx::Context, v::Cstring, len::Csize_t)::Cint
    return 1
end

function on_map_start(ctx::Context)::Cint
    return 1
end

function on_map_key(ctx::Context, v::Cstring, len::Csize_t)::Cint
    return 1
end

function on_map_end(ctx::Context)::Cint
    return 1
end

function on_array_start(ctx::Context)::Cint
    return 1
end

function on_array_end(ctx::Context)::Cint
    return 1
end

function checkstatus(handle::Ptr{Cvoid}, status::Cint, text::Vector{UInt8})
    if status == Cint(OK)
        return
    elseif status == Cint(CLIENT_CANCELLED)
        throw(YAJLError(CLIENT_CANCELLED, ""))
    elseif status == Cint(ERROR)
        err = ccall(yajl[:get_error], Cstring, (Ptr{Cvoid}, Cint, Ptr{Cuchar}, Csize_t),
                    handle, 1, text, length(text))
        reason = unsafe_string(err)
        ccall(yajl[:free_error], Cvoid, (Ptr{Cvoid}, Cstring), handle, err)
        throw(YAJLError(ERROR, reason))
    end
end

function parse(io::IO; callbacks::Callbacks=callbacks[], chunk::Int=2^16,
               ctx::T=Context(), options::UInt8=0x0) where T
    handle = ccall(yajl[:alloc], Ptr{Cvoid}, (Ptr{Callbacks}, Ptr{Cvoid}, Ptr{T}),
                   Ref(callbacks), C_NULL, Ref(ctx))

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
end

function __init__()
    lib = Libdl.dlopen(:libyajl)
    for f in [:alloc, :complete_parse, :config, :free, :free_error, :get_error, :parse]
        yajl[f] = Libdl.dlsym(lib, Symbol(:yajl_, f))
    end
    callbacks[] = Callbacks(
        @cfunction(on_null, Cint, (Ref{Context},)),
        @cfunction(on_boolean, Cint, (Ref{Context}, Cint)),
        C_NULL,
        C_NULL,
        @cfunction(on_number, Cint, (Ref{Context}, Cstring, Csize_t)),
        @cfunction(on_string, Cint, (Ref{Context}, Cstring, Csize_t)),
        @cfunction(on_map_start, Cint, (Ref{Context},)),
        @cfunction(on_map_key, Cint, (Ref{Context}, Cstring, Csize_t)),
        @cfunction(on_map_end, Cint, (Ref{Context},)),
        @cfunction(on_array_start, Cint, (Ref{Context},)),
        @cfunction(on_array_end, Cint, (Ref{Context},)),
    )
end

end
