using Test
using YAJL

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

# struct DoNothing1 <: YAJL.Context end
# struct DoNothing2 <: YAJL.Context end
# struct DoNothing3 <: YAJL.Context end

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
        # How do you @test_throws or @test_logs with a macro?

        # @test_throws ArgumentError @yajl foo(::DoNothing1) = nothing)

        # @test_logs @yajl number(::DoNothing1, ::Ptr{UInt8}, ::Int) = true
        # @test_logs (:warn, r"no effect") @yajl integer(::DoNothing1, ::Int) = nothing
        # @test_logs (:warn, r"no effect") @yajl double(::DoNothing1, ::Float64) = nothing

        # @test_logs @yajl integer(::DoNothing2, ::Ptr{UInt8}, ::Int) = nothing
        # @test_logs (:info, r"disables") @yajl number(::DoNothing2, ::Ptr{UInt8}, ::Int) = nothing

        # @test_logs @yajl double(::DoNothing3, ::Ptr{UInt8}, ::Int) = nothing
        # @test_logs (:info, r"disables") @yajl number(::DoNothing2, ::Ptr{UInt8}, ::Int) = nothing
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
