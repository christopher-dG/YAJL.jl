using Test
using YAJL

mutable struct Count <: YAJL.Context
    n::Int
    Count() = new(0)
end

YAJL.complete(ctx::Count) = ctx.n
@yajl number(ctx::Count, ::Ptr{UInt8}, ::Int) = ctx.n += 1

@testset "YAJL.jl" begin
    @testset "Basics" begin
        io = IOBuffer("[" * repeat("0,", 1000000) * "0]")
        expected = 1000001
        @test YAJL.run(io, Count()) == expected
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
