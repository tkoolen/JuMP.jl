# variable.jl
# Test coverage for Variable

# Constructors
mcon = Model("min")
@defVar(mcon, nobounds)
@defVar(mcon, lbonly >= 0)
@defVar(mcon, ubonly <= 1)
@defVar(mcon, 0 <= bothb <= 1)
@defVar(mcon, 0 <= onerange[-5:5] <= 10)
@defVar(mcon, onerangeub[-7:1] <= 10, Int)
@defVar(mcon, manyrangelb[0:1,10:20,1:1] >= 2)
@assert getLower(manyrangelb[0,15,1]) == 2
s = ["Green","Blue"]
@defVar(mcon, x[-10:10,s] <= 5.5, Int)
@assert getUpper(x[-4,"Green"]) == 5.5

# Test setters/getters
# Name
m = Model("max")
@defVar(m, 0 <= x <= 2)
@assert getName(x) == "x"
setName(x, "x2")
@assert getName(x) == "x2"
setName(x, "")
@assert getName(x) == "_col1"

# Bounds
@assert getLower(x) == 0
@assert getUpper(x) == 2
setLower(x, 1)
@assert getLower(x) == 1
setUpper(x, 3)
@assert getUpper(x) == 3
