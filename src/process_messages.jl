# This file is a part of Julia. License is MIT: https://julialang.org/license

# data stored by the owner of a remote reference
def_rv_channel() = Channel(1)
mutable struct RemoteValue
    c::AbstractChannel
    clientset::BitSet # Set of workerids that have a reference to this channel.
                      # Keeping ids instead of a count aids in cleaning up upon
                      # a worker exit.

    waitingfor::Int   # processor we need to hear from to fill this, or 0

    synctake::Union{ReentrantLock, Nothing}  # A lock used to synchronize the
                      # specific case of a local put! / remote take! on an
                      # unbuffered store. github issue #29932

    function RemoteValue(c)
        c_is_buffered = false
        try
            c_is_buffered = isbuffered(c)
        catch
        end

        if c_is_buffered
            return new(c, BitSet(), 0, nothing)
        else
            return new(c, BitSet(), 0, ReentrantLock())
        end
    end
end

wait(rv::RemoteValue) = wait(rv.c)

# A wrapper type to handle issue #29932 which requires locking / unlocking of
# RemoteValue.synctake outside of lexical scope.
struct SyncTake
    v::Any
    rv::RemoteValue
end

## core messages: do, call, fetch, wait, ref, put! ##
struct RemoteException <: Exception
    pid::Int
    captured::CapturedException
end

"""
    capture_exception(ex::RemoteException, bt)

Returns `ex::RemoteException` which has already captured a backtrace (via it's [`CapturedException`](@ref) field `captured`).
"""
Base.capture_exception(ex::RemoteException, bt) = ex

"""
    RemoteException(captured)

Exceptions on remote computations are captured and rethrown locally.  A `RemoteException`
wraps the `pid` of the worker and a captured exception. A `CapturedException` captures the
remote exception and a serializable form of the call stack when the exception was raised.
"""
RemoteException(captured; role= :default) = RemoteException(myid(role=role), captured)
function showerror(io::IO, re::RemoteException#=; role= :default=#)
    (re.pid != myid(#=role = role=#)) && print(io, "On worker ", re.pid, ":\n")
    showerror(io, re.captured#=; role = role=#)
end

function run_work_thunk(thunk::Function, print_error::Bool; role=:default)
    local result
    try
        result = thunk()
    catch err
        ce = CapturedException(err, catch_backtrace())
        result = RemoteException(ce; role=role)
        print_error && showerror(stderr, ce#=; role = role=#)
    end
    return result
end
function run_work_thunk(rv::RemoteValue, thunk; role= :default)
    put!(rv, run_work_thunk(thunk, false; role=role))
    nothing
end

function schedule_call(rid, thunk; role= :default)
    return lock(client_refs) do
        rv = RemoteValue(def_rv_channel())
        (PGRP(role = role)::ProcessGroup).refs[rid] = rv
        push!(rv.clientset, rid.whence)
        errormonitor(@async run_work_thunk(rv, thunk; role=role))
        return rv
    end
end


function deliver_result(sock::IO, msg, oid, value; role= :default)
    #print("$(myid(role=role)) sending result $oid\n")
    if msg === :call_fetch || isa(value, RemoteException)
        val = value
    else
        val = :OK
    end
    try
        send_msg_now(sock, MsgHeader(oid), ResultMsg(val); role = role)
    catch e
        # terminate connection in case of serialization error
        # otherwise the reading end would hang
        @error "Fatal error on process $(myid(role=role))" exception=e,catch_backtrace()
        wid = worker_id_from_socket(sock; role = role)
        close(sock)
        if myid(role=role)==1
            rmprocs(wid)
        elseif wid == 1
            exit(1)
        else
            remote_do(rmprocs, 1, wid; role = role)
        end
    end
end

## message event handlers ##
function process_messages(r_stream::TCPSocket, w_stream::TCPSocket, incoming::Bool=true; role= :default)
    errormonitor(@async process_tcp_streams(r_stream, w_stream, incoming; role = role))
end

function process_tcp_streams(r_stream::TCPSocket, w_stream::TCPSocket, incoming::Bool; role= :default)
    Sockets.nagle(r_stream, false)
    Sockets.quickack(r_stream, true)
    wait_connected(r_stream)
    if r_stream != w_stream
        Sockets.nagle(w_stream, false)
        Sockets.quickack(w_stream, true)
        wait_connected(w_stream)
    end
    message_handler_loop(r_stream, w_stream, incoming; role = role)
end

"""
    process_messages(r_stream::IO, w_stream::IO, incoming::Bool=true)

Called by cluster managers using custom transports. It should be called when the custom
transport implementation receives the first message from a remote worker. The custom
transport must manage a logical connection to the remote worker and provide two
`IO` objects, one for incoming messages and the other for messages addressed to the
remote worker.
If `incoming` is `true`, the remote peer initiated the connection.
Whichever of the pair initiates the connection sends the cluster cookie and its
Julia version number to perform the authentication handshake.

See also [`cluster_cookie`](@ref).
"""
function process_messages(r_stream::IO, w_stream::IO, incoming::Bool=true; role= :default)
    errormonitor(@async message_handler_loop(r_stream, w_stream, incoming; role = role))
end

function message_handler_loop(r_stream::IO, w_stream::IO, incoming::Bool; role= :default)
    wpid=0          # the worker r_stream is connected to.
    boundary = similar(MSG_BOUNDARY)
    try
        version = process_hdr(r_stream, incoming; role = role)
        serializer = ClusterSerializer(r_stream)

        # The first message will associate wpid with r_stream
        header = deserialize_hdr_raw(r_stream)
        msg = deserialize_msg(serializer)
        handle_msg(msg, header, r_stream, w_stream, version; role = role)
        wpid = worker_id_from_socket(r_stream; role = role)
        @assert wpid > 0

        readbytes!(r_stream, boundary, length(MSG_BOUNDARY))

        while true
            reset_state(serializer)
            header = deserialize_hdr_raw(r_stream)
            #println("header: ", header)

            try
                msg = invokelatest(deserialize_msg, serializer)
            catch e
                #println("*************************************************")
                # Deserialization error; discard bytes in stream until boundary found
                boundary_idx = 1
                while true
                    # This may throw an EOF error if the terminal boundary was not written
                    # correctly, triggering the higher-scoped catch block below
                    byte = read(r_stream, UInt8)
                    if byte == MSG_BOUNDARY[boundary_idx]
                        boundary_idx += 1
                        if boundary_idx > length(MSG_BOUNDARY)
                            break
                        end
                    else
                        boundary_idx = 1
                    end
                end

                # remotecalls only rethrow RemoteExceptions. Any other exception is treated as
                # data to be returned. Wrap this exception in a RemoteException.
                remote_err = RemoteException(myid(role=role), CapturedException(e, catch_backtrace()))
                # println("Deserialization error. ", remote_err)
                if !null_id(header.response_oid)
                    ref = lookup_ref(header.response_oid; role = role)
                    put!(ref, remote_err)
                end
                if !null_id(header.notify_oid)
                    deliver_result(w_stream, :call_fetch, header.notify_oid, remote_err; role = role)
                end
                continue
            end
            readbytes!(r_stream, boundary, length(MSG_BOUNDARY))

            #println("got msg: ", typeof(msg))
            handle_msg(msg, header, r_stream, w_stream, version; role = role)
        end
    catch e
        oldstate = W_UNKNOWN_STATE

        # Check again as it may have been set in a message handler but not propagated to the calling block above
        if wpid < 1
            wpid = worker_id_from_socket(r_stream; role = role)
        end

        if wpid < 1
            println(stderr, e, CapturedException(e, catch_backtrace()))
            println(stderr, "Process($(myid(role=role))) - Unknown remote, closing connection.")
        elseif !(wpid in map_del_wrkr)
            werr = worker_from_id(wpid)
            oldstate = @atomic werr.state
            set_worker_state(werr, W_TERMINATED)

            # If unhandleable error occurred talking to pid 1, exit
            if wpid == 1
                if isopen(w_stream)
                    @error "Fatal error on process $(myid(role=role))" exception=e,catch_backtrace()
                end
                exit(1)
            end

            # Will treat any exception as death of node and cleanup
            # since currently we do not have a mechanism for workers to reconnect
            # to each other on unhandled errors
            deregister_worker(wpid; role = role)
        end

        close(r_stream)
        close(w_stream)

        if (myid(role=role) == 1) && (wpid > 1)
            if oldstate != W_TERMINATING
                println(stderr, "Worker $wpid terminated.")
                rethrow()
            end
        end

        return nothing
    end
end

function process_hdr(s, validate_cookie; role= :default)
    if validate_cookie
        cookie = read(s, HDR_COOKIE_LEN)
        if length(cookie) < HDR_COOKIE_LEN
            error("Cookie read failed. Connection closed by peer.")
        end

        self_cookie = cluster_cookie()
        for i in 1:HDR_COOKIE_LEN
            if UInt8(self_cookie[i]) != cookie[i]
                error("Process($(myid(role = role))) - Invalid connection credentials sent by remote.")
            end
        end
    end

    # When we have incompatible julia versions trying to connect to each other,
    # and can be detected, raise an appropriate error.
    # For now, just return the version.
    version = read(s, HDR_VERSION_LEN)
    if length(version) < HDR_VERSION_LEN
        error("Version read failed. Connection closed by peer.")
    end

    return VersionNumber(strip(String(version)))
end

function handle_msg(msg::CallMsg{:call}, header, r_stream, w_stream, version; role= :default)
    schedule_call(header.response_oid, ()->invokelatest(msg.f, msg.args...; msg.kwargs...); role = role)
end
function handle_msg(msg::CallMsg{:call_fetch}, header, r_stream, w_stream, version; role= :default)
    #@info "handle ", msg
    errormonitor(@async begin
        v = run_work_thunk(()->invokelatest(msg.f, msg.args...; msg.kwargs...), false; role=role)
        if isa(v, SyncTake)
            try
                deliver_result(w_stream, :call_fetch, header.notify_oid, v.v; role = role)
            finally
                unlock(v.rv.synctake)
            end
        else
            deliver_result(w_stream, :call_fetch, header.notify_oid, v; role = role)
        end
        nothing
    end)
end

function handle_msg(msg::CallWaitMsg, header, r_stream, w_stream, version; role= :default)
    errormonitor(@async begin
        rv = schedule_call(header.response_oid, ()->invokelatest(msg.f, msg.args...; msg.kwargs...); role = role)
        deliver_result(w_stream, :call_wait, header.notify_oid, fetch(rv.c); role = role)
        nothing
    end)
end

function handle_msg(msg::RemoteDoMsg, header, r_stream, w_stream, version; role= :default)
    errormonitor(@async run_work_thunk(()->invokelatest(msg.f, msg.args...; msg.kwargs...), true; role=role))
end

function handle_msg(msg::ResultMsg, header, r_stream, w_stream, version; role= :default)
    put!(lookup_ref(header.response_oid; role = role), msg.value)
end

function handle_msg(msg::IdentifySocketMsg, header, r_stream, w_stream, version; role= :default)
    # register a new peer worker connection
    w = Worker(msg.from_pid, r_stream, w_stream, cluster_manager; version=version, role = role)
    send_connection_hdr(w, false)
    send_msg_now(w, MsgHeader(), IdentifySocketAckMsg(); role = role)
    notify(w.initialized)
end

function handle_msg(msg::IdentifySocketAckMsg, header, r_stream, w_stream, version; role= :default)
    w = map_sock_wrkr[r_stream]
    w.version = version
end

function handle_msg(msg::JoinPGRPMsg, header, r_stream, w_stream, version; role= :default)
    #LPROC.id = msg.self_pid
    myid!(msg.self_pid, role=role)
    controller = Worker(1, r_stream, w_stream, cluster_manager; version=version, role = role)
    notify(controller.initialized)
    register_worker(LPROC)
    topology(msg.topology; role=role)

    if !msg.enable_threaded_blas
        Base.disable_library_threading()
    end

    lazy = msg.lazy
    PGRP(role = role).lazy = lazy

    @sync for (connect_at, rpid) in msg.other_workers
        wconfig = WorkerConfig()
        wconfig.connect_at = connect_at

        let rpid=rpid, wconfig=wconfig
            if lazy
                # The constructor registers the object with a global registry.
                Worker(rpid, ()->connect_to_peer(cluster_manager, rpid, wconfig; role = role); role = role)
            else
                @async connect_to_peer(cluster_manager, rpid, wconfig; role = role)
            end
        end
    end

    send_connection_hdr(controller, false)
    send_msg_now(controller, MsgHeader(RRID(0,0), header.notify_oid), JoinCompleteMsg(Sys.CPU_THREADS, getpid()); role = role)
end

function connect_to_peer(manager::ClusterManager, rpid::Int, wconfig::WorkerConfig; role= :default)
    try
        (r_s, w_s) = connect(manager, rpid, wconfig)
        w = Worker(rpid, r_s, w_s, manager; config=wconfig, role = role)
        process_messages(w.r_stream, w.w_stream, false; role = role)
        send_connection_hdr(w, true)
        send_msg_now(w, MsgHeader(), IdentifySocketMsg(myid(role=role)), role = role)
        notify(w.initialized)
    catch e
        @error "Error on $(myid(role=role)) while connecting to peer $rpid, exiting" exception=e,catch_backtrace()
        exit(1)
    end
end

function handle_msg(msg::JoinCompleteMsg, header, r_stream, w_stream, version; role= :default)
    w = map_sock_wrkr[r_stream]
    environ = something(w.config.environ, Dict())
    environ[:cpu_threads] = msg.cpu_threads
    w.config.environ = environ
    w.config.ospid = msg.ospid
    w.version = version

    ntfy_channel = lookup_ref(header.notify_oid; role = role)
    put!(ntfy_channel, wid(w,role=role))

    push!(default_worker_pool(role=role), wid(w,role=role), role = role)
end
