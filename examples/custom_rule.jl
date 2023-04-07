# # Enzyme custom rules tutorial

# The goal of this tutorial is to give a simple example of defining a custom rule with Enzyme.
# Specifically, our goal will be to write custom rules for the following function `f`:

function f(y, x)
    y .= x.^2
    return sum(y) 
end

# Our function `f` populates its first input `y` with the element-wise square of `x`.
# In addition to doing this mutation, it returns `sum(y)` as output. What a sneaky function!

# In this case, Enzyme can differentiate through `f` automatically. For example, using forward mode:

using Enzyme
x  = [3.0, 1.0]
dx = [1.0, 0.0]
y  = [0.0, 0.0]
dy = [0.0, 0.0]

g(y, x) = f(y, x)^2 # function to differentiate 

@show autodiff(Forward, g, Duplicated(y, dy), Duplicated(x, dx)) # derivative of g w.r.t. x[1]
@show dy; # derivative of y w.r.t. x[1] when g is run

# (See the [AutoDiff API tutorial](autodiff.md) for more information on using `autodiff`.)

# But there may be special cases where we need to write a custom rule to help Enzyme out.
# Let's see how to write a custom rule for `f`!

# !!! warning "Don't use custom rules unnecessarily!"
#     Enzyme can efficiently handle a wide range of constructs, and so a custom rule should only be required
#     in certain special cases. For example, a function may make a foreign call that Enzyme cannot differentiate,
#     or we may have higher-level mathematical knowledge that enables us to write a more efficient rule. 
#     Even in these cases, try to make your custom rule encapsulate the minimum possible construct that Enzyme
#     cannot differentiate, rather than expanding the scope of the rule unnecessarily.
#     For pedagogical purposes, we will disregard this principle here and go ahead and write a custom rule for `f` :)

# ## Defining our first (forward-mode) rule 

# First, we import the functions [`EnzymeRules.forward`](@ref), [`EnzymeRules.augmented_primal`](@ref),
# and [`EnzymeRules.reverse`](@ref).
# We need to overload `forward` in order to define a custom forward rule, and we need to overload
# `augmented_primal` and `reverse` in order to define a custom reverse rule.

import .EnzymeRules: forward, reverse, augmented_primal
using .EnzymeRules

# In this section, we write a simple forward rule to start out:

function forward(func::Const{typeof(f)}, ::Type{<:Duplicated}, y::Duplicated, x::Duplicated)
    println("Using custom rule!")
    out = func.val(y.val, x.val)
    y.dval .= 2 .* x.val .* x.dval
    return Duplicated(out, sum(y.dval)) 
end

# In the signature of our rule, we have made use of `Enzyme`'s activity annotations. Let's break down each one:
# - the [`Const`](@ref) annotation on `f` indicates that we accept a function `f` that does not have a derivative component,
#   which makes sense since `f` itself does not depend on any parameters.
# - the [`Duplicated`](@ref) annotation given in the second argument annotates the return value of `f`. This means that
#   our `forward` function should return an output of type `Duplicated`, containing the original output `sum(y)` and its derivative.
# - the [`Duplicated`](@ref) annotations for `x` and `y` mean that our `forward` function handles inputs `x` and `y`
#   which have been marked as `Duplicated`. We should update their shadows with their derivative contributions. 

# In the logic of our forward function, we run the original function, populate `y.dval` (the shadow of `y`), 
# and finally return a `Duplicated` for the output as promised. Let's see our rule in action! 
# With the same setup as before:

x  = [3.0, 1.0]
dx = [1.0, 0.0]
y  = [0.0, 0.0]
dy = [0.0, 0.0]

g(y, x) = f(y, x)^2 # function to differentiate

@show autodiff(Forward, g, Duplicated(y, dy), Duplicated(x, dx)) # derivative of g w.r.t. x[1]
@show dy; # derivative of y w.r.t. x[1] when g is run

# We see that our custom forward rule has been triggered and gives the same answer as before.

# ## Handling more activities 

# Our custom rule applies for the specific set of activities that are annotated for `f` in the above `autodiff` call. 
# However, Enzyme has a number of other annotations. Let us consider a particular case as an example, where the output
# has a [`DuplicatedNoNeed`](@ref) annotation. This means we are only interested in its derivative, not its value.
# To squeeze the last drop of performance, the below rule avoids computing the output of the original function and 
# just computes its derivative.

function forward(func::Const{typeof(f)}, ::Type{<:DuplicatedNoNeed}, y::Duplicated, x::Duplicated)
    println("Using custom rule with DuplicatedNoNeed output.")
    y.val .= x.val.^2 
    y.dval .= 2 .* x.val .* x.dval
    return sum(y.dval)
end

# Our rule is triggered, for example, when we call `autodiff` directly on `f`, as the output's derivative isn't needed:

x  = [3.0, 1.0]
dx = [1.0, 0.0]
y  = [0.0, 0.0]
dy = [0.0, 0.0]

@show autodiff(Forward, f, Duplicated(y, dy), Duplicated(x, dx)) # derivative of f w.r.t. x[1]
@show dy; # derivative of y w.r.t. x[1] when f is run

# !!! note "Custom rule dispatch"
#     When multiple custom rules for a function are defined, the correct rule is chosen using 
#     [Julia's multiple dispatch](https://docs.julialang.org/en/v1/manual/methods/#Methods).
#     In particular, it is important to understand that the custom rule does not *determine* the
#     activities of the inputs and the outputs: rather, `Enzyme` decides the activity annotations independently,
#     and then *dispatches* to the custom rule handling the activities, if one exists.

# Finally, it may be that either `x` or `y` are marked as [`Const`](@ref). We can in fact handle this case, 
# along with the previous two cases, all together in a single rule:

function forward(func::Const{typeof(f)}, RT::Type{<:Union{DuplicatedNoNeed, Duplicated}}, 
                 y::Union{Const, Duplicated}, x::Union{Const, Duplicated})
    println("Using our general custom rule!")
    y.val .= x.val.^2 
    if !(x <: Const) && !(y <: Const)
        y.dval .= 2 .* x.val .* x.dval
    elseif !(y <: Const) 
        y.dval .= 0
    end
    if RT <: DuplicatedNoNeed
        return sum(y.dval)
    else
        return Duplicated(sum(y.val), sum(y.dval))
    end
end

# Note that there are also exist batched duplicated annotations for forward mode, namely [`BatchDuplicated`](@ref)
# and [`BatchDuplicatedNoNeed`](@ref), which are not covered in this tutorial.

# ## Defining a reverse-mode rule

# Finally, let's look at how to write a simple reverse-mode rule! 
# First, we write a method for [`EnzymeRules.augmented_primal`](@ref):

function augmented_primal(config::ConfigWidth{1}, func::Const{typeof(f)}, ::Type{<:Active},
                          y::Duplicated, x::Duplicated)
    println("In custom augmented primal rule.")
    if needs_primal(config)
        return AugmentedReturn(func.val(y.val, x.val), nothing, nothing)
    else
        return AugmentedReturn(nothing, nothing, nothing)
    end
end

# Let's unpack our signature for `augmented_primal` :
# * We accepted a [`EnzymeRules.Config`](@ref) object with a specified width of 1, which means that our rule does not support batched reverse mode.
# * Our function `f` was annotated [`Const`](@ref) as usual.
# * We dispatched on an [`Active`](@ref) annotation for the return value. This is a special annotation for scalar values, such as our return value,
#   that indicates that that we care about the value's derivative but we need not explicitly allocate a mutable shadow since it is a scalar value.
# * We annotated `x` and `y` with [`Duplicated`](@ref) as in the forward mode case.

# The body of our function simply checks if the `config` requires the primal, running it if so.
# Our function returns an `AugmentedReturn` object specifying the return value, its shadow, and any extra tape information (none in this csae).
# Note that we return a shadow of `nothing` since the return value is marked [`Active`](@ref).

# Now, we write a method for [`EnzymeRules.reverse`](@ref):

function reverse(config::ConfigWidth{1}, func::Const{typeof(f)}, out::Active, tape,
                 y::Duplicated, x::Duplicated)
    println("In custom reverse rule.")
    y.dval .+= out.val 
    x.dval .+= 2 .* x.val .* y.dval # accumulate into shadow, don't assign!
    return ()
end

# The activities used in the signature match what we used for `augmented_primal`. 
# One key difference is that we know receive an *instance* `out` of [`Active`](@ref) for the return type, not just a type annotation.
# Here, `out.val` stores the derivative value for `out` (not the original return value!).
# Using this derivative value, we accumulate the backpropagated derivatives for `x` and `y` into their shadows. 

# Finally, let's see our reverse rule in action!

x  = [3.0, 1.0]
dx = [0.0, 0.0]
y  = [0.0, 0.0]
dy = [0.0, 0.0]

g(y, x) = f(y, x)^2

autodiff(Reverse, g, Duplicated(y, dy), Duplicated(x, dx)) # derivative of f w.r.t. y[1]
@show dx # derivative of f w.r.t. x
@show dy; # derivative of f w.r.t. y
