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
        @test YAJL.run(io, Count()) == 1000001
    end
end
