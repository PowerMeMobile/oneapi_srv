-module(k1api_app).

-behaviour(application).

-compile([{parse_transform, lager_transform}]).

-include("logging.hrl").
-include_lib("oa_proto/include/oa_pb.hrl").

%% Application callbacks
-export([
    start/2,
    prep_stop/1,
    stop/1
    ]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    ?log_info("k1api initializing...", []),
    Result = k1api_sup:start_link(),
    
    ?log_info("backend connector initializing...", []),
    
    {ok, AuthReqQ} = application:get_env(auth_req_q),
    {ok, AuthRespQ} = application:get_env(auth_resp_q),
    oabc:register_2way(auth, AuthReqQ, AuthRespQ),

    {ok, BatchQ} = application:get_env(batches_q), 
    oabc:register_fw(batch, BatchQ),

    {ok, SubscriptionsQ} = application:get_env(subscriptions_q),
    oabc:register_bw(subsriptions, SubscriptionsQ, k1api_oabc_handler),

    {ok, SrvControlQ} = application:get_env(server_control_q),
    oabc:register_bw(control, SrvControlQ, k1api_oabc_handler),

    {ok, BackEndQ} = application:get_env(backend_control_q),
    oabc:register_fw(backend, BackEndQ),

    ?log_info("server up event sending...", []),
    ServerUpEvent = #frontendupevent{
        reset_subscriptions = false,
        auth_q = AuthReqQ,
        register_q = BatchQ,
        control_q = SrvControlQ},
    ServerUpEventProto = oa_pb:encode_frontendupevent(ServerUpEvent),
    oabc:call(backend, ServerUpEventProto, [{content_type, <<"frontendupevent">>}]),

    ?log_info("eoneapi initializing...", []),
	EOneAPIProps = [
		{port, 8081},
		{sms_handler, k1api_sms_handler}
	],
	eoneapi:start_service(EOneAPIProps),

	Result.

prep_stop(State) ->
    ?log_info("server down event sending...", []),
    FrontendDownEvent = #frontenddownevent{
                            reason = "normal",
                            timestamp = "120409143943"},
    FrontendDownEventProto = oa_pb:encode_frontenddownevent(FrontendDownEvent),
    oabc:call(backend, FrontendDownEventProto, [{content_type, <<"frontenddownevent">>}]),
    State.

stop(_State) ->
    ok.