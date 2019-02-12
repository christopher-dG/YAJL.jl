using Test
using YAJL

# A janky @test_throws that works with macro calls wrapped in an Expr.
test_throws(ex::Expr) = test_throws(ArgumentError, ex)
function test_throws(T::Type{<:Exception}, ex::Expr)
    try
        eval(ex)
        @error "Test failed: expected $T to be thrown" ex
        @test false
    catch e
        e isa LoadError && (e = e.error)
        if e isa T
            @test true
        else
            @error "Test failed: expected $T to be thrown, $(typeof(e)) thrown instead" ex
            @test false
        end
    end
end

mutable struct Counter <: YAJL.Context
    n::Int
    Counter() = new(0)
end
YAJL.complete(ctx::Counter) = ctx.n
@yajl integer(ctx::Counter, ::Int) = ctx.n += 1

struct UntilN <: YAJL.Context
    n::Int
    xs::Vector{Int}
    UntilN(n::Int) = new(n, [])
end
YAJL.complete(ctx::UntilN) = ctx.xs
@yajl function integer(ctx::UntilN, n::Int)
    return if n == ctx.n
        false
    else
        push!(ctx.xs, n)
        true
    end
end

struct DoNothing <: YAJL.Context end
struct DoNothing2 <: YAJL.Context end
struct DoNothing3 <: YAJL.Context end

@testset "YAJL.jl" begin
    @testset "Basics" begin
        io = IOBuffer("[" * repeat("0,", 1000000) * "0]")
        expected = 1000001
        @test YAJL.run(io, Counter()) == expected
    end

    @testset "Cancellation" begin
        io = IOBuffer("[" * repeat("0,", 10) * "1,1,1,1,1]")
        expected = zeros(Int, 10)
        @test YAJL.run(io, UntilN(1)) == expected
    end

    @testset "@yajl errors + warnings" begin
        # Invalid callback name.
        test_throws(:(@yajl foo(::DoNothing) = nothing))
        # Untyped callback arguments.
        test_throws(:(@yajl null(ctx) = nothing))
        test_throws(:(@yajl integer(ctx::DoNothing, v) = nothing))
        # Invalid arguments.
        test_throws(:(@yajl null() = nothing))
        test_throws(:(@yajl null(::Int) = nothing))
        test_throws(:(@yajl null(::DoNothing, ::Any) = nothing))
        test_throws(:(@yajl boolean(::DoNothing, v::String) = nothing))
        test_throws(:(@yajl integer(::DoNothing, v::String) = nothing))
        test_throws(:(@yajl double(::DoNothing, v::String) = nothing))
        test_throws(:(@yajl number(::DoNothing, v::String, len::Int) = nothing))
        test_throws(:(@yajl number(::DoNothing, v::Cstring, len::String) = nothing))
        # Useless/destructive number callbacks.
        @test_logs eval(:(@yajl number(::DoNothing, ::Ptr{UInt8}, ::Int) = true))
        @test_logs (:warn, r"no effect") eval(:(@yajl integer(::DoNothing, ::Int) = nothing))
        @test_logs (:warn, r"no effect") eval(:(@yajl double(::DoNothing, ::Float64) = nothing))
        @test_logs eval(:(@yajl integer(::DoNothing2, ::Int) = nothing))
        @test_logs (:warn, r"disables") eval(:(@yajl number(::DoNothing2, ::Ptr{UInt8}, ::Int) = nothing))
        @test_logs eval(:(@yajl double(::DoNothing3, ::Float64) = nothing))
        @test_logs (:warn, r"disables") eval(:(@yajl number(::DoNothing3, ::Ptr{UInt8}, ::Int) = nothing))
    end

    @testset "Minifier" begin
        io = IOBuffer("""
        [
          {
            "foo": null,
            "bar": 0,
            "baz": 1.2,
            "qux": "qux"
          },
          1,
          2,
          3
        ]
        """)
        expected = """[{"foo":null,"bar":0,"baz":1.2,"qux":"qux"},1,2,3]"""
        @test String(take!(YAJL.run(io, YAJL.Minifier(IOBuffer())))) == expected
    end
end
