#  Copyright 2017, Iain Dunning, Joey Huchette, Miles Lubin, and contributors
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.
#############################################################################
# JuMP
# An algebraic modeling language for Julia
# See http://github.com/JuliaOpt/JuMP.jl
#############################################################################

isdefined(Base, :__precompile__) && __precompile__()

module JuMP

importall Base.Operators
import Base.map

import MathProgBase

using Calculus
using ReverseDiffSparse
using ForwardDiff

export
# Objects
    Model, Variable, Norm, AffExpr, QuadExpr, SOCExpr,
    LinearConstraint, QuadConstraint, SDConstraint, SOCConstraint,
    NonlinearConstraint,
    ConstraintRef,
# Functions
    # Model related
    getobjectivevalue, getobjective,
    getobjectivesense, setobjectivesense, setsolver,
    writeLP, writeMPS,
    addSOS1, addSOS2, solve,
    internalmodel,
    # Variable
    setname, getname, setlowerbound, setupperbound, getlowerbound, getupperbound,
    getvalue, setvalue, getdual, setcategory, getcategory,
    getvariable, getconstraint,
    linearindex,
    # Expressions and constraints
    linearterms,

# Macros and support functions
    @LinearConstraint, @LinearConstraints, @QuadConstraint, @QuadConstraints,
    @SOCConstraint, @SOCConstraints,
    @expression, @expressions, @NLexpression, @NLexpressions,
    @variable, @variables, @constraint, @constraints,
    @NLconstraint, @NLconstraints,
    @SDconstraint, @SDconstraints,
    @objective, @NLobjective,
    @NLparameter, @constraintref

include("JuMPContainer.jl")
include("utils.jl")

###############################################################################
# Model class
# Keeps track of all model and column info
abstract AbstractModel
type Model <: AbstractModel
    obj#::QuadExpr
    objSense::Symbol

    linconstr#::Vector{LinearConstraint}
    quadconstr
    sosconstr
    socconstr
    sdpconstr

    # Column data
    numCols::Int
    colNames::Vector{String}
    colNamesIJulia::Vector{String}
    colLower::Vector{Float64}
    colUpper::Vector{Float64}
    colCat::Vector{Symbol}

    customNames::Vector

    # Variable cones of the form, e.g. (:SDP, 1:9)
    varCones::Vector{Tuple{Symbol,Any}}

    # Solution data
    objVal
    colVal::Vector{Float64}
    redCosts::Vector{Float64}
    linconstrDuals::Vector{Float64}
    conicconstrDuals::Vector{Float64}
    constrDualMap::Vector{Vector{Int}}
    # Vector of the same length as sdpconstr.
    # sdpconstrSym[c] is the list of pairs (i,j), i > j
    # such that a symmetry-enforcing constraint has been created
    # between sdpconstr[c].terms[i,j] and sdpconstr[c].terms[j,i]
    sdpconstrSym::Vector{Vector{Tuple{Int,Int}}}
    # internal solver model object
    internalModel
    # Solver+option object from MathProgBase
    solver::MathProgBase.AbstractMathProgSolver
    internalModelLoaded::Bool
    # callbacks
    callbacks
    # lazycallback
    # cutcallback
    # heurcallback

    # hook into a solve call...function of the form f(m::Model; kwargs...),
    # where kwargs get passed along to subsequent solve calls
    solvehook
    # ditto for a print hook
    printhook

    # List of JuMPContainer{Variables} associated with model
    dictList::Vector

    # storage vector for merging duplicate terms
    indexedVector::IndexedVector{Float64}

    nlpdata#::NLPData
    simplify_nonlinear_expressions::Bool

    varDict::Dict{Symbol,Any} # dictionary from variable names to variable objects
    conDict::Dict{Symbol,Any} # dictionary from constraint names to constraint objects
    varData::ObjectIdDict

    map_counter::Int # number of times we call getvalue, getdual, getlowerbound and getupperbound on a JuMPContainer, so that we can print out a warning
    operator_counter::Int # number of times we add large expressions

    # Extension dictionary - e.g. for robust
    # Extensions should define a type to hold information particular to
    # their functionality, and store an instance of the type in this
    # dictionary keyed on an extension-specific symbol
    ext::Dict{Symbol,Any}
end

# dummy solver
type UnsetSolver <: MathProgBase.AbstractMathProgSolver
end

# Default constructor
function Model(;solver=UnsetSolver(), simplify_nonlinear_expressions::Bool=false)
    if !isa(solver,MathProgBase.AbstractMathProgSolver)
        error("solver argument ($solver) must be an AbstractMathProgSolver")
    end
    Model(zero(QuadExpr),              # obj
          :Min,                        # objSense
          LinearConstraint[],          # linconstr
          QuadConstraint[],            # quadconstr
          SOSConstraint[],             # sosconstr
          SOCConstraint[],             # socconstr
          SDConstraint[],              # sdpconstr
          0,                           # numCols
          String[],                    # colNames
          String[],                    # colNamesIJulia
          Float64[],                   # colLower
          Float64[],                   # colUpper
          Symbol[],                    # colCat
          Variable[],                  # customNames
          Vector{Tuple{Symbol,Any}}[], # varCones
          0,                           # objVal
          Float64[],                   # colVal
          Float64[],                   # redCosts
          Float64[],                   # linconstrDuals
          Float64[],                   # conicconstrDuals
          Vector{Int}[],               # constrDualMap
          Vector{Tuple{Int,Int}}[],    # sdpconstrSym
          nothing,                     # internalModel
          solver,                      # solver
          false,                       # internalModelLoaded
          Any[],                       # callbacks
          nothing,                     # solvehook
          nothing,                     # printhook
          Any[],                       # dictList
          IndexedVector(Float64,0),    # indexedVector
          nothing,                     # nlpdata
          simplify_nonlinear_expressions, # ...
          Dict{Symbol,Any}(),          # varDict
          Dict{Symbol,Any}(),          # conDict
          ObjectIdDict(),              # varData
          0,                           # map_counter
          0,                           # operator_counter
          Dict{Symbol,Any}(),          # ext
    )
end

# Getters/setters
MathProgBase.numvar(m::Model) = m.numCols
MathProgBase.numlinconstr(m::Model) = length(m.linconstr)
MathProgBase.numquadconstr(m::Model) = length(m.quadconstr)
numsocconstr(m::Model) = length(m.socconstr)
numsosconstr(m::Model) = length(m.sosconstr)
numsdconstr(m::Model) = length(m.sdpconstr)
numnlconstr(m::Model) = m.nlpdata !== nothing ? length(m.nlpdata.nlconstr) : 0

function MathProgBase.numconstr(m::Model)
    c = length(m.linconstr) + length(m.quadconstr) + length(m.socconstr) + length(m.sosconstr) + length(m.sdpconstr)
    if m.nlpdata !== nothing
        c += length(m.nlpdata.nlconstr)
    end
    return c
end

for f in MathProgBase.SolverInterface.methods_by_tag[:rewrap]
    eval(Expr(:import,:MathProgBase,f))
    @eval function $f(m::Model)
        # check internal model exists
        if !m.internalModelLoaded
            error("Model not solved")
        else
            return $f(internalmodel(m))
        end
    end
    eval(Expr(:export,f))
end

function getobjective(m::Model)
    traits = ProblemTraits(m)
    if traits.nlp
        error("getobjective() not supported for nonlinear models")
    end
    return m.obj
end

getobjectivevalue(m::Model) = m.objVal
getobjectivesense(m::Model) = m.objSense
function setobjectivesense(m::Model, newSense::Symbol)
    if (newSense != :Max && newSense != :Min)
        error("Model sense must be :Max or :Min")
    end
    m.objSense = newSense
end
setobjective(m::Model, something::Any) =
    error("in setobjective: needs three arguments: model, objective sense (:Max or :Min), and expression.")

setobjective(::Model, ::Symbol, x::AbstractArray) =
    error("in setobjective: array of size $(size(x)) passed as objective; only scalar objectives are allowed")

function setsolver(m::Model, solver::MathProgBase.AbstractMathProgSolver)
    m.solver = solver
    m.internalModel = nothing
    m.internalModelLoaded = false
    nothing
end
# Deep copy the model
function Base.copy(source::Model)

    dest = Model()
    dest.solver = source.solver  # The two models are linked by this

    # Objective
    dest.obj = copy(source.obj, dest)
    dest.objSense = source.objSense

    # Constraints
    dest.linconstr  = map(c->copy(c, dest), source.linconstr)
    dest.quadconstr = map(c->copy(c, dest), source.quadconstr)
    dest.sosconstr  = map(c->copy(c, dest), source.sosconstr)
    dest.sdpconstr  = map(c->copy(c, dest), source.sdpconstr)

    # Variables
    dest.numCols = source.numCols
    dest.colNames = source.colNames[:]
    dest.colNamesIJulia = source.colNamesIJulia[:]
    dest.colLower = source.colLower[:]
    dest.colUpper = source.colUpper[:]
    dest.colCat = source.colCat[:]

    # varCones
    dest.varCones = copy(source.varCones)

    # callbacks and hooks
    if !isempty(source.callbacks)
        error("Copying callbacks is not supported")
    end
    if source.solvehook !== nothing
        dest.solvehook = source.solvehook
    end
    if source.printhook !== nothing
        dest.printhook = source.printhook
    end

    # variable/extension dicts
    if !isempty(source.ext)
        dest.ext = similar(source.ext)
        for (key, val) in source.ext
            dest.ext[key] = try
                copy(source.ext[key])
            catch
                error("Error copying extension dictionary. Is `copy` defined for all your user types?")
            end
        end
    end
    dest.varDict = Dict{Symbol,Any}()
    for (symb,v) in source.varDict
        dest.varDict[symb] = copy(v, dest)
    end

    dest.conDict = Dict{Symbol,Any}()
    # TODO: implement constraint copying
    # for (symb,v) in source.conDict
    #     dest.conDict[symb] = copy(v, dest)
    # end

    # varData---possibly shouldn't copy

    if source.nlpdata !== nothing
        dest.nlpdata = copy(source.nlpdata)
    end

    return dest
end

internalmodel(m::Model) = m.internalModel

setsolvehook(m::Model, f) = (m.solvehook = f)
setprinthook(m::Model, f) = (m.printhook = f)


#############################################################################
# AbstractConstraint
# Abstract base type for all constraint types
abstract AbstractConstraint
# Abstract base type for all scalar types
# In JuMP, used only for Variable. Useful primarily for extensions
abstract AbstractJuMPScalar

Base.start(::AbstractJuMPScalar) = false
Base.next(x::AbstractJuMPScalar, state) = (x, true)
Base.done(::AbstractJuMPScalar, state) = state
Base.isempty(::AbstractJuMPScalar) = false

#############################################################################
# Variable class
# Doesn't actually do much, just a pointer back to the model
immutable Variable <: AbstractJuMPScalar
    m::Model
    col::Int
end

linearindex(x::Variable) = x.col
Base.isequal(x::Variable,y::Variable) = (x.col == y.col) && (x.m === y.m)

Variable(m::Model, lower, upper, cat::Symbol, name::AbstractString="", value::Number=NaN) =
    error("Attempt to create scalar Variable with lower bound of type $(typeof(lower)) and upper bound of type $(typeof(upper)). Bounds must be scalars in Variable constructor.")

function Variable(m::Model,lower::Number,upper::Number,cat::Symbol,name::AbstractString="",value::Number=NaN)
    m.numCols += 1
    push!(m.colNames, name)
    push!(m.colNamesIJulia, name)
    push!(m.colLower, convert(Float64,lower))
    push!(m.colUpper, convert(Float64,upper))
    push!(m.colCat, cat)
    push!(m.colVal,value)
    if cat == :Fixed
        @assert lower == upper
        m.colVal[end] = lower
    end
    if m.internalModelLoaded
        if method_exists(MathProgBase.addvar!, (typeof(m.internalModel),Vector{Int},Vector{Float64},Float64,Float64,Float64))
            MathProgBase.addvar!(m.internalModel,float(lower),float(upper),0.0)
        else
            Base.warn_once("Solver does not appear to support adding variables to an existing model. JuMP's internal model will be discarded.")
            m.internalModelLoaded = false
        end
    end
    return Variable(m, m.numCols)
end

# Name setter/getters
function setname(v::Variable,n::AbstractString)
    push!(v.m.customNames, v)
    v.m.colNames[v.col] = n
    v.m.colNamesIJulia[v.col] = n
end
getname(m::Model, col) = var_str(REPLMode, m, col)
getname(v::Variable) = var_str(REPLMode, v.m, v.col)

# Bound setter/getters
function setlowerbound(v::Variable,lower::Number)
    v.m.colCat[v.col] == :Fixed && error("use setvalue for changing the value of a fixed variable")
    v.m.colLower[v.col] = lower
end
function setupperbound(v::Variable,upper::Number)
    v.m.colCat[v.col] == :Fixed && error("use setvalue for changing the value of a fixed variable")
    v.m.colUpper[v.col] = upper
end
getlowerbound(v::Variable) = v.m.colLower[v.col]
getupperbound(v::Variable) = v.m.colUpper[v.col]

# Value setter/getter
function setvalue(v::Variable, val::Number)
    v.m.colVal[v.col] = val
    if v.m.colCat[v.col] == :Fixed
        error("setvalue for fixed variables is no longer supported. Use JuMP.fix instead.")
    end
end

# Fix a variable that was not previously fixed
function fix(v::Variable, val::Number)
    v.m.colCat[v.col] = :Fixed
    v.m.colLower[v.col] = val
    v.m.colUpper[v.col] = val
    v.m.colVal[v.col] = val
end

# internal method that doesn't print a warning if the value is NaN
_getValue(v::Variable) = v.m.colVal[v.col]

getvaluewarn(v) = Base.warn("Variable value not defined for $(getname(v)). Check that the model was properly solved.")

function getvalue(v::Variable)
    ret = _getValue(v)
    if isnan(ret)
        getvaluewarn(v)
    end
    ret
end

function getvalue(arr::AbstractArray{Variable})
    ret = similar(arr, Float64)
    # return immediately for empty array
    if isempty(ret)
        return ret
    end
    # warnedyet is set to true if we've already warned for a component of a JuMPContainer
    warnedyet = false
    m = first(arr).m
    # whether this was constructed via @variable, essentially
    registered = haskey(m.varData, arr)
    for I in eachindex(arr)
        v = arr[I]
        value = _getValue(v)
        ret[I] = value
        if !warnedyet && isnan(value)
            if registered
                Base.warn("Variable value not defined for component of $(m.varData[arr].name). Check that the model was properly solved.")
                warnedyet = true
            else
                Base.warn("Variable value not defined for $(m.colNames[v.col]). Check that the model was properly solved.")
            end
        end
    end
    # Copy printing data from @variable for Array{Variable} to corresponding Array{Float64} of values
    if registered
        m.varData[ret] = m.varData[arr]
    end
    ret
end

# Dual value (reduced cost) getter

# internal method that doesn't print a warning if the value is NaN
_getDual(v::Variable) = v.m.redCosts[v.col]

getdualwarn(::Variable) = warn("Variable bound duals (reduced costs) not available. Check that the model was properly solved and no integer variables are present.")

function getdual(v::Variable)
    if length(v.m.redCosts) < MathProgBase.numvar(v.m)
        getdualwarn(v)
        NaN
    else
        _getDual(v)
    end
end

const var_cats = [:Cont, :Int, :Bin, :SemiCont, :SemiInt]
function setcategory(v::Variable, cat::Symbol)
    cat in var_cats || error("Unrecognized variable category $cat. Should be one of:\n    $var_cats")
    v.m.colCat[v.col] = cat
end

getcategory(v::Variable) = v.m.colCat[v.col]

Base.zero(::Type{Variable}) = AffExpr(Variable[],Float64[],0.0)
Base.zero(::Variable) = zero(Variable)
Base.one(::Type{Variable}) = AffExpr(Variable[],Float64[],1.0)
Base.one(::Variable) = one(Variable)

function verify_ownership(m::Model, vec::AbstractVector{Variable})
    n = length(vec)
    @inbounds for i in 1:n
        vec[i].m !== m && return false
    end
    return true
end

Base.copy(v::Variable, new_model::Model) = Variable(new_model, v.col)
Base.copy(x::Void, new_model::Model) = nothing
function Base.copy(v::AbstractArray{Variable}, new_model::Model)
    ret = similar(v, Variable, size(v))
    for I in eachindex(v)
        ret[I] = Variable(new_model, v[I].col)
    end
    ret
end

# Copy methods for variable containers
Base.copy(d::JuMPContainer) = map(copy, d)
Base.copy(d::JuMPContainer, new_model::Model) = map(x -> copy(x, new_model), d)

###############################################################################
# GenericAffineExpression, AffExpr
# GenericRangeConstraint, LinearConstraint
include("affexpr.jl")

###############################################################################
# GenericQuadExpr, QuadExpr
# GenericQuadConstraint, QuadConstraint
include("quadexpr.jl")

##########################################################################
# GenericNorm, Norm
# GenericNormExpr. GenericSOCExpr, SOCExpr
# GenericSOCConstraint, SOCConstraint
include("norms.jl")

##########################################################################
# SOSConstraint  (special ordered set constraints)
include("sos.jl")

##########################################################################
# SDConstraint is a (dual) semidefinite constraint of the form
# ∑ cᵢ Xᵢ ≥ D, where D is a n×n symmetric data matrix, cᵢ are
# scalars, and Xᵢ are n×n symmetric variable matrices. The inequality
# is taken w.r.t. the psd partial order.
type SDConstraint <: AbstractConstraint
    terms
end

# Special-case X ≥ 0, which is often convenient
function SDConstraint(lhs::AbstractMatrix, rhs::Number)
    rhs == 0 || error("Cannot construct a semidefinite constraint with nonzero scalar bound $rhs")
    SDConstraint(lhs)
end

function addconstraint(m::Model, c::SDConstraint)
    push!(m.sdpconstr,c)
    m.internalModelLoaded = false
    ConstraintRef{Model,SDConstraint}(m,length(m.sdpconstr))
end

# helper method for mapping going on below
Base.copy(x::Number, new_model::Model) = copy(x)

Base.copy(c::SDConstraint, new_model::Model) =
    SDConstraint(map(t -> copy(t, new_model), c.terms))


##########################################################################
# ConstraintRef
# Reference to a constraint for retrieving solution info
immutable ConstraintRef{M<:AbstractModel,T<:AbstractConstraint}
    m::M
    idx::Int
end

typealias LinConstrRef ConstraintRef{Model,LinearConstraint}

LinearConstraint(ref::LinConstrRef) = ref.m.linconstr[ref.idx]::LinearConstraint

linearindex(x::ConstraintRef) = x.idx

# internal method that doesn't print a warning if the value is NaN
_getDual(c::LinConstrRef) = c.m.linconstrDuals[c.idx]

getdualwarn{T<:Union{ConstraintRef, Int}}(::T) = warn("Dual solution not available. Check that the model was properly solved and no integer variables are present.")

function getdual(c::LinConstrRef)
    if length(c.m.linconstrDuals) != MathProgBase.numlinconstr(c.m)
        getdualwarn(c)
        NaN
    else
        _getDual(c)
    end
end

# Returns the number of non-infinity and nonzero bounds on variables
function getNumBndRows(m::Model)
    numBounds = 0
    for i in 1:m.numCols
        seen = false
        lb, ub = m.colLower[i], m.colUpper[i]
        for (_,cone) in m.varCones
            if i in cone
                seen = true
                @assert lb == -Inf && ub == Inf
                break
            end
        end

        if !seen
            if lb != -Inf && lb != 0
                numBounds += 1
            end
            if ub != Inf && ub != 0
                numBounds += 1
            end
        end
    end
    return numBounds
end

# Returns the number of second-order cone constraints
getNumRows(c::SOCConstraint) = length(c.normexpr.norm.terms) + 1
getNumSOCRows(m::Model) = sum(getNumRows.(m.socconstr))

# Returns the number of rows used by SDP constraints in the MPB conic representation
# (excluding symmetry constraints)
#   Julia seems to not be able to infer the return type (probably because c.terms is Any)
#   so getNumSDPRows tries to call zero(Any)... Using ::Int solves this issue
function getNumRows(c::SDConstraint)::Int
    n = size(c.terms, 1)
    (n * (n+1)) ÷ 2
end
getNumSDPRows(m::Model) = sum(getNumRows.(m.sdpconstr))

# Returns the number of symmetry-enforcing constraints for SDP constraints
function getNumSymRows(m::Model)
    sum(map(length, m.sdpconstrSym))
end

# Returns the dual variables corresponding to
# m.sdpconstr[idx] if issdp is true
# m.socconstr[idx] if sdp is not true
function getconicdualaux(m::Model, idx::Int, issdp::Bool)
    numLinRows = MathProgBase.numlinconstr(m)
    numBndRows = getNumBndRows(m)
    numSOCRows = getNumSOCRows(m)
    numSDPRows = getNumSDPRows(m)
    numSymRows = getNumSymRows(m)
    numRows = numLinRows + numBndRows + numSOCRows + numSDPRows + numSymRows
    if length(m.conicconstrDuals) != numRows
        # solve might not have been called so m.constrDualMap might be empty
        getdualwarn(idx)
        c = issdp ? m.sdpconstr[idx] : m.socconstr[idx]
        duals = fill(NaN, getNumRows(c))
        if issdp
            duals, Float64[]
        else
            duals
        end
    else
        offset = numLinRows + numBndRows
        if issdp
            offset += length(m.socconstr)
        end
        dual = m.conicconstrDuals[m.constrDualMap[offset + idx]]
        if issdp
            offset += length(m.sdpconstr)
            symdual = m.conicconstrDuals[m.constrDualMap[offset + idx]]
            dual, symdual
        else
            dual
        end
    end
end

function getdual(c::ConstraintRef{Model,SOCConstraint})
    getconicdualaux(c.m, c.idx, false)
end

# Let S₊ be the cone of symmetric semidefinite matrices in
# the n*(n+1)/2 dimensional space of symmetric R^{nxn} matrices.
# It is well known that S₊ is a self-dual proper cone.
# Let P₊ be the cone of symmetric semidefinite matrices in
# the n^2 dimensional space of R^{nxn} matrices and
# let D₊ be the cone of matrices A such that A+Aᵀ ∈ P₊.
# P₊ is not proper since it is not solid (as it is not n^2 dimensional) so it is not ensured that (P₊)** = P₊
# However this is the case since, as we will see, (P₊)* = D₊ and (D₊)* = P₊.
# * Let us first see why (P₊)* = D₊.
#   If B is symmetric, then ⟨A,B⟩ = ⟨Aᵀ,Bᵀ⟩ = ⟨Aᵀ,B⟩ so 2⟨A,B⟩ = ⟨A,B⟩ + ⟨Aᵀ,B⟩ = ⟨A+Aᵀ,B⟩
#   Therefore, ⟨A,B⟩ ⩾ 0 for all B ∈ P₊ if and only if ⟨A+Aᵀ,B⟩ ⩾ 0 for all B ∈ P₊
#   Since A+Aᵀ is symmetric and we know that S₊ is self-dual, we have shown that (P₊)*
#   is the set of matrices A such that A+Aᵀ is PSD
# * Let us now see why (D₊)* = P₊.
#   Since A ∈ D₊ implies that Aᵀ ∈ D₊, B ∈ (D₊)* means that ⟨A+Aᵀ,B⟩ ⩾ 0 for any A ∈ D₊ hence B is positive semi-definite.
#   To see why it should be symmetric, simply notice that if B[i,j] < B[j,i] then ⟨A,B⟩ can be made arbitrarily small by setting
#   A[i,j] += s
#   A[j,i] -= s
#   with s arbitrarilly large, and A stays in D₊ as A+Aᵀ does not change.
#
# Typically, SDP primal/dual are presented as
# min ⟨C, X⟩                                                                max ∑ b_ky_k
# ⟨A_k, X⟩ = b_k ∀k                                                         C - ∑ A_ky_k ∈ S₊
#        X ∈ S₊                                                                      y_k free ∀k
# Here, as we allow A_i to be non-symmetric, we should rather use
# min ⟨C, X⟩                                                                max ∑ b_ky_k
# ⟨A_k, X⟩ = b_k ∀k                                                         C - ∑ A_ky_k ∈ P₊
#        X ∈ D₊                                                                      y_k free ∀k
# which is implemented as
# min ⟨C, Z⟩ + (C[i,j]-C[j-i])s[i,j]                                        max ∑ b_ky_k
# ⟨A_k, Z⟩ + (A_k[i,j]-A_k[j,i])s[i,j] = b_k ∀k                   C+Cᵀ - ∑ (A_k+A_kᵀ)y_k ∈ S₊
#       s[i,j] free  1 ⩽ i,j ⩽ n with i > j     C[i,j]-C[j-i] - ∑ (A_k[i,j]-A_k[j,i])y_k = 0  1 ⩽ i,j ⩽ n with i > j
#        Z ∈ S₊                                                                      y_k free ∀k
# where "∈ S₊" only look at the diagonal and upper diagonal part.
# In the last primal program, we have the variables Z = X + Xᵀ and a upper triangular matrix S such that X = Z + S - Sᵀ
function getdual(c::ConstraintRef{Model,SDConstraint})
    dual, symdual = getconicdualaux(c.m, c.idx, true)
    n = size(c.m.sdpconstr[c.idx].terms, 1)
    X = Matrix{eltype(dual)}(n, n)
    @assert length(dual) == convert(Int, n*(n+1)/2)
    idx = 0
    for i in 1:n
        for j in i:n
            idx += 1
            if i == j
                X[i,j] = dual[idx]
            else
                X[j,i] = X[i,j] = dual[idx] / sqrt(2)
            end
        end
    end
    if !isempty(symdual)
        @assert length(symdual) == length(c.m.sdpconstrSym[c.idx])
        idx = 0
        for (i,j) in c.m.sdpconstrSym[c.idx]
            idx += 1
            s = symdual[idx]
            X[i,j] -= s
            X[j,i] += s
        end
    end
    X
end

function setRHS(c::LinConstrRef, rhs::Number)
    constr = c.m.linconstr[c.idx]
    sen = sense(constr)
    if sen == :range
        error("Modifying range constraints is currently unsupported.")
    elseif sen == :(==)
        constr.lb = float(rhs)
        constr.ub = float(rhs)
    elseif sen == :>=
        constr.lb = float(rhs)
    else
        @assert sen == :<=
        constr.ub = float(rhs)
    end
end

Variable(m::Model,lower::Number,upper::Number,cat::Symbol,objcoef::Number,
    constraints::JuMPArray,coefficients::AbstractVector{Float64}, name::AbstractString="", value::Number=NaN) =
    Variable(m, lower, upper, cat, objcoef, constraints.innerArray, coefficients, name, value)

# add variable to existing constraints
function Variable(m::Model,lower::Number,upper::Number,cat::Symbol,objcoef::Number,
    constraints::AbstractVector,coefficients::AbstractVector{Float64}, name::AbstractString="", value::Number=NaN)
    for c in constraints
        if !isa(c, LinConstrRef)
            error("Unexpected constraint of type $(typeof(c)). Column-wise modeling only supported for linear constraints")
        end
    end
    @assert cat != :Fixed || (lower == upper)
    m.numCols += 1
    push!(m.colNames, name)
    push!(m.colNamesIJulia, name)
    push!(m.colLower, convert(Float64,lower))
    push!(m.colUpper, convert(Float64,upper))
    push!(m.colCat, cat)
    push!(m.colVal, value)
    if cat == :Fixed
        @assert lower == upper
        m.colVal[end] = lower
    end
    v = Variable(m,m.numCols)
    # add to existing constraints
    @assert length(constraints) == length(coefficients)
    for i in 1:length(constraints)
        c::LinearConstraint = m.linconstr[constraints[i].idx]
        coef = coefficients[i]
        push!(c.terms.vars,v)
        push!(c.terms.coeffs,coef)
    end
    push!(m.obj.aff.vars, v)
    push!(m.obj.aff.coeffs,objcoef)

    if m.internalModelLoaded
        if method_exists(MathProgBase.addvar!, (typeof(m.internalModel),Vector{Int},Vector{Float64},Float64,Float64,Float64))
            MathProgBase.addvar!(m.internalModel,Int[c.idx for c in constraints],coefficients,float(lower),float(upper),float(objcoef))
        else
            Base.warn_once("Solver does not appear to support adding variables to an existing model. JuMP's internal model will be discarded.")
            m.internalModelLoaded = false
        end
    end

    return v
end

# handle dictionary of variables
function registervar(m::Model, varname::Symbol, value)
    if haskey(m.varDict, varname)
        Base.warn_once("A variable named $varname is already attached to this model. If creating variables programmatically, consider using the anonymous variable syntax x = @variable(m, [1:N], ...).")
        m.varDict[varname] = nothing # indicate duplicate variable
    else
        m.varDict[varname] = value
    end
    return value
end
registervar(m::Model, varname, value) = value # variable name isn't a simple symbol, ignore

function registercon(m::Model, conname::Symbol, value)
    if haskey(m.conDict, conname)
        Base.warn_once("A constraint named $conname is already attached to this model. If creating constraints programmatically, consider using the anonymous constraint syntax con = @constraint(m, ...).")
        m.conDict[conname] = nothing # indicate duplicate constraint
    else
        m.conDict[conname] = value
    end
    return value
end
registercon(m::Model, conname, value) = value # constraint name isn't a simple symbol, ignore

function getvariable(m::Model, varname::Symbol)
    if !haskey(m.varDict, varname)
        error("No variable with name $varname")
    elseif m.varDict[varname] === nothing
        error("Multiple variables with name $varname")
    else
        return m.varDict[varname]
    end
end

function getconstraint(m::Model, conname::Symbol)
    if !haskey(m.conDict, conname)
        error("No constraint with name $conname")
    elseif m.conDict[conname] === nothing
        error("Multiple constraints with name $conname")
    else
        return m.conDict[conname]
    end
end

# usage warnings
function mapcontainer_warn(f, x::JuMPContainer, var_or_expr)
    isempty(x) && return
    v = first(values(x))
    m = v.m
    m.map_counter += 1
    if m.map_counter > 400
        # It might not be f that was called the 400 first times but most probably it is f
        Base.warn_once("$f has been called on a collection of $(var_or_expr)s a large number of times. For performance reasons, this should be avoided. Instead of $f(x)[a,b,c], use $f(x[a,b,c]) to avoid temporary allocations.")
    end
end
mapcontainer_warn(f, x::JuMPContainer{Variable}) = mapcontainer_warn(f, x, "variable")
mapcontainer_warn{E}(f, x::JuMPContainer{E}) = mapcontainer_warn(f, x, "expression")
getvalue_warn(x::JuMPContainer) = nothing

function operator_warn(lhs::AffExpr,rhs::AffExpr)
    if length(lhs.vars) > 50 || length(rhs.vars) > 50
        if length(lhs.vars) > 1
            m = lhs.vars[1].m
            m.operator_counter += 1
            if m.operator_counter > 20000
                Base.warn_once("The addition operator has been used on JuMP expressions a large number of times. This warning is safe to ignore but may indicate that model generation is slower than necessary. For performance reasons, you should not add expressions in a loop. Instead of x += y, use append!(x,y) to modify x in place. If y is a single variable, you may also use push!(x, coef, y) in place of x += coef*y.")
            end
        end
    end
    return
end
operator_warn(lhs,rhs) = nothing

##########################################################################
# Types used in the nonlinear code
immutable NonlinearExpression
    m::Model
    index::Int
end

immutable NonlinearParameter <: AbstractJuMPScalar
    m::Model
    index::Int
end


##########################################################################
# Behavior that's uniform across all JuMP "scalar" objects

typealias JuMPTypes Union{AbstractJuMPScalar,
                          NonlinearExpression,
                          Norm,
                          GenericAffExpr,
                          QuadExpr,
                          SOCExpr}
typealias JuMPScalars Union{Number,JuMPTypes}

# would really want to do this on ::Type{T}, but doesn't work on v0.4
Base.eltype{T<:JuMPTypes}(::T) = T
Base.size(::JuMPTypes) = ()
Base.size(x::JuMPTypes,d::Int) = 1
Base.ndims(::JuMPTypes) = 0


##########################################################################
# Operator overloads
include("operators.jl")
# Writers - we support MPS (MILP + QuadObj), LP (MILP)
include("writers.jl")
# Macros - @defVar, sum{}, etc.
include("macros.jl")
# Solvers
include("solvers.jl")
# Callbacks - lazy, cuts, ...
include("callbacks.jl")
# Nonlinear-specific code
include("nlp.jl")
# Pretty-printing of JuMP-defined types.
include("print.jl")
# Deprecations
include("deprecated.jl")

getvalue{T<:JuMPTypes}(arr::AbstractArray{T}) = map(getvalue, arr)

function setvalue{T<:AbstractJuMPScalar}(set::AbstractArray{T}, val::AbstractArray)
    promote_shape(size(set), size(val)) # Check dimensions match
    for I in eachindex(set)
        setvalue(set[I], val[I])
    end
    nothing
end


##########################################################################
end
