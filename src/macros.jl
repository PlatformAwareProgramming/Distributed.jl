# This file is a part of Julia. License is MIT: https://julialang.org/license

let nextidx = Threads.Atomic{Int}(0)
    global nextproc
    function nextproc(;role= :default)
        idx = Threads.atomic_add!(nextidx, 1)
        return workers(role = role)[(idx % nworkers(role = role)) + 1]
    end
end

spawnat(p, thunk; role= :default) = remotecall(thunk, p; role = role)

spawn_somewhere(thunk; role= :default) = spawnat(nextproc(role = role),thunk; role = role)

"""
    @spawn expr

Create a closure around an expression and run it on an automatically-chosen process,
returning a [`Future`](@ref) to the result.
This macro is deprecated; `@spawnat :any expr` should be used instead.

# Examples
```julia-repl
julia> addprocs(3);

julia> f = @spawn myid()
Future(2, 1, 5, nothing)

julia> fetch(f)
2

julia> f = @spawn myid()
Future(3, 1, 7, nothing)

julia> fetch(f)
3
```

!!! compat "Julia 1.3"
    As of Julia 1.3 this macro is deprecated. Use `@spawnat :any` instead.
"""


#macro spawn(expr, role = :(:default))

function check_args_2(args...)
    na = length(args)
    if na==1
        role = Expr(:kw, :role, :(:defaut)) #:(role = :default)
        expr = args[1]
    elseif na==2 
        role = args[1]
        expr = args[2]
    else
        throw(ArgumentError("wrong number of arguments to spawn"))
    end
    return role, expr
end

macro spawn(args...)
    rolearg, expr = check_args_2(args...)

    thunk = esc(:(()->($expr)))
    var = esc(Base.sync_varname)
    quote
        local ref = spawn_somewhere($thunk; $(esc(rolearg)))
        if $(Expr(:islocal, var))
            put!($var, ref)
        end
        ref
    end
end


"""
    @spawnat p expr

Create a closure around an expression and run the closure
asynchronously on process `p`. Return a [`Future`](@ref) to the result.

If `p` is the quoted literal symbol `:any`, then the system will pick a
processor to use automatically. Using `:any` will not apply any form of
load-balancing, consider using a [`WorkerPool`](@ref) and [`remotecall(f,
::WorkerPool)`](@ref) if you need load-balancing.

# Examples
```julia-repl
julia> addprocs(3);

julia> f = @spawnat 2 myid()
Future(2, 1, 3, nothing)

julia> fetch(f)
2

julia> f = @spawnat :any myid()
Future(3, 1, 7, nothing)

julia> fetch(f)
3
```

!!! compat "Julia 1.3"
    The `:any` argument is available as of Julia 1.3.
"""

function check_args_3a(args...)
    na = length(args)
    if na==2
        role = Expr(:kw, :role, :(:defaut)) #:(role = :default)
        p = args[1]
        expr = args[2]
    elseif na==3 
        role = args[1]
        p = args[2]
        expr = args[3]
    else
        throw(ArgumentError("wrong number of arguments to spawnat"))
    end
    return role, p, expr
end

macro spawnat(args...)
   rolearg, p, expr = check_args_3a(args...)

   #@info rolearg, typeof(rolearg)

   thunk = esc(:(()->($expr)))
   var = esc(Base.sync_varname)
   if p === QuoteNode(:any)
       spawncall = :(spawn_somewhere($thunk; $(esc(rolearg))))
   else
       spawncall = :(spawnat($(esc(p)), $thunk; $(esc(rolearg))))
   end
   quote
        local ref = $spawncall
        if $(Expr(:islocal, var))
            put!($var, ref)
        end
        ref
    end
end


"""
    @fetch expr

Equivalent to `fetch(@spawnat :any expr)`.
See [`fetch`](@ref) and [`@spawnat`](@ref).

# Examples
```julia-repl
julia> addprocs(3);

julia> @fetch myid()
2

julia> @fetch myid()
3

julia> @fetch myid()
4

julia> @fetch myid()
2
```
"""

macro fetch(args...)

    rolearg, expr = check_args_2(args...)

    thunk = esc(:(()->($expr)))
    :(remotecall_fetch($thunk, nextproc(); $(esc(rolearg))))
end

"""
    @fetchfrom

Equivalent to `fetch(@spawnat p expr)`.
See [`fetch`](@ref) and [`@spawnat`](@ref).

# Examples
```julia-repl
julia> addprocs(3);

julia> @fetchfrom 2 myid()
2

julia> @fetchfrom 4 myid()
4
```
"""


macro fetchfrom(args...)
    rolearg, p, expr = check_args_3a(args...)
    thunk = esc(:(()->($expr)))
    :(remotecall_fetch($thunk, $(esc(p)); $(esc(rolearg))))
end

# extract a list of modules to import from an expression
extract_imports!(imports, x) = imports
function extract_imports!(imports, ex::Expr)
    if Meta.isexpr(ex, (:import, :using))
        push!(imports, ex)
    elseif Meta.isexpr(ex, :let)
        extract_imports!(imports, ex.args[2])
    elseif Meta.isexpr(ex, (:toplevel, :block))
        for arg in ex.args
            extract_imports!(imports, arg)
        end
    end
    return imports
end
extract_imports(x) = extract_imports!(Any[], x)

"""
    @everywhere [procs()] expr

Execute an expression under `Main` on all `procs`.
Errors on any of the processes are collected into a
[`CompositeException`](@ref) and thrown. For example:

    @everywhere bar = 1

will define `Main.bar` on all current processes. Any processes added later
(say with [`addprocs()`](@ref)) will not have the expression defined.

Unlike [`@spawnat`](@ref), `@everywhere` does not capture any local variables.
Instead, local variables can be broadcast using interpolation:

    foo = 1
    @everywhere bar = \$foo

The optional argument `procs` allows specifying a subset of all
processes to have execute the expression.

Similar to calling `remotecall_eval(Main, procs, expr)`, but with two extra features:

- `using` and `import` statements run on the calling process first, to ensure
  packages are precompiled.
- The current source file path used by `include` is propagated to other processes.
"""

function check_args_3b(args...)

    na = length(args)
    if na==1
        rolearg = Expr(:kw, :role, :(:defaut)) #:(role = :default)
        reducer = nothing
        loop = args[1]
    elseif na==2
        if isa(args[1], Expr) && args[1].head == :(=) && args[1].args[1] === :role 
            rolearg = args[1]
            reducer = nothing
            loop = args[2]
        else
            rolearg = Expr(:kw, :role, :(:defaut)) #:(role = :default)
            reducer = args[1]
            loop = args[2]
        end
    elseif na==3
        rolearg = args[1]
        reducer = args[2]
        loop = args[3]
    else
        throw(ArgumentError("wrong number of arguments to @distributed"))
    end

    return rolearg, reducer, loop
end

macro everywhere(args...)

    rolearg, procs, ex = check_args_3b(args...)

    if isnothing(procs)
        procs = GlobalRef(@__MODULE__, :procs)
        return esc(:($(Distributed).@everywhere $rolearg $procs(;$rolearg) $ex))
    else
        imps = extract_imports(ex)
        return quote
            $(isempty(imps) ? nothing : Expr(:toplevel, imps...)) # run imports locally first
            let ex = Expr(:toplevel, :(task_local_storage()[:SOURCE_PATH] = $(get(task_local_storage(), :SOURCE_PATH, nothing))), $(esc(Expr(:quote, ex)))),
                procs = $(esc(procs))
                remotecall_eval(Main, procs, ex; $(esc(rolearg)))
            end
        end
          
    end

end

"""
    remotecall_eval(m::Module, procs, expression)

Execute an expression under module `m` on the processes
specified in `procs`.
Errors on any of the processes are collected into a
[`CompositeException`](@ref) and thrown.

See also [`@everywhere`](@ref).
"""
function remotecall_eval(m::Module, procs, ex; role=:default)
    @sync begin
        run_locally = 0
        for pid in procs
            if pid == myid(role=role)
                run_locally += 1
            else
                @async_unwrap remotecall_wait(Core.eval, pid, m, ex; role=role)
            end
        end
        yield() # ensure that the remotecalls have had a chance to start

        # execute locally last as we do not want local execution to block serialization
        # of the request to remote nodes.
        for _ in 1:run_locally
            @async Core.eval(m, ex)
        end
    end
    nothing
end

# optimized version of remotecall_eval for a single pid
# and which also fetches the return value
function remotecall_eval(m::Module, pid::Int, ex; role=:default)
    return remotecall_fetch(Core.eval, pid, m, ex; role=role)
end


# Statically split range [firstIndex,lastIndex] into equal sized chunks for np processors
function splitrange(firstIndex::Int, lastIndex::Int, np::Int)
    each, extras = divrem(lastIndex-firstIndex+1, np)
    nchunks = each > 0 ? np : extras
    chunks = Vector{UnitRange{Int}}(undef, nchunks)
    lo = firstIndex
    for i in 1:nchunks
        hi = lo + each - 1
        if extras > 0
            hi += 1
            extras -= 1
        end
        chunks[i] = lo:hi
        lo = hi+1
    end
    return chunks
end

function preduce(reducer, f, R; role = :default)
    chunks = splitrange(Int(firstindex(R)), Int(lastindex(R)), nworkers(role=role))
    all_w = workers(role=role)[1:length(chunks)]

    w_exec = Task[]
    for (idx,pid) in enumerate(all_w)
        t = Task(()->remotecall_fetch(f, pid, reducer, R, first(chunks[idx]), last(chunks[idx]), role=role))
        schedule(t)
        push!(w_exec, t)
    end
    reduce(reducer, Any[fetch(t) for t in w_exec])
end

function pfor(f, R; role = :default)
    t = @async @sync for c in splitrange(Int(firstindex(R)), Int(lastindex(R)), nworkers(role=role))
        @spawnat role=role :any f(R, first(c), last(c))
    end
    errormonitor(t)
end

function make_preduce_body(var, body)
    quote
        function (reducer, R, lo::Int, hi::Int)
            $(esc(var)) = R[lo]
            ac = $(esc(body))
            if lo != hi
                for $(esc(var)) in R[(lo+1):hi]
                    ac = reducer(ac, $(esc(body)))
                end
            end
            ac
        end
    end
end

function make_pfor_body(var, body)
    quote
        function (R, lo::Int, hi::Int)
            for $(esc(var)) in R[lo:hi]
                $(esc(body))
            end
        end
    end
end

"""
    @distributed

A distributed memory, parallel for loop of the form :

    @distributed [reducer] for var = range
        body
    end

The specified range is partitioned and locally executed across all workers. In case an
optional reducer function is specified, `@distributed` performs local reductions on each worker
with a final reduction on the calling process.

Note that without a reducer function, `@distributed` executes asynchronously, i.e. it spawns
independent tasks on all available workers and returns immediately without waiting for
completion. To wait for completion, prefix the call with [`@sync`](@ref), like :

    @sync @distributed for var = range
        body
    end
"""
macro distributed(args...)
    
    rolearg, reducer, loop = check_args_3b(args...)
    
    if !isa(loop,Expr) || loop.head !== :for
        error("malformed @distributed loop")
    end
    var = loop.args[1].args[1]
    r = loop.args[1].args[2]
    body = loop.args[2]
    if Meta.isexpr(body, :block) && body.args[end] isa LineNumberNode
        resize!(body.args, length(body.args) - 1)
    end
    if isnothing(reducer)
        syncvar = esc(Base.sync_varname)
        return quote
            local ref = pfor($(make_pfor_body(var, body)), $(esc(r)); $(esc(rolearg)))
            if $(Expr(:islocal, syncvar))
                put!($syncvar, ref)
            end
            ref
        end
    else
        return :(preduce($(esc(reducer)), $(make_preduce_body(var, body)), $(esc(r)); $(esc(rolearg)))) # TO CHECK (role ?)
    end
end
