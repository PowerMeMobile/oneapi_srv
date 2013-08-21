-module(k1api_delivery_status_srv).

-behaviour(gen_server).

%% API
-export([
	start_link/0,
	get/4
]).

%% GenServer Callbacks
-export([
	init/1,
	handle_cast/2,
	handle_call/3,
	handle_info/2,
	code_change/3,
	terminate/2
]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("eoneapi/include/eoneapi.hrl").
-include_lib("queue_fabric/include/queue_fabric.hrl").
-include("gen_server_spec.hrl").
-include("application.hrl").
-include("logging.hrl").

-record(state, {
	chan 					:: pid(),
	reply_to 				:: binary(),
	pending_workers = []	:: [#pworker{}],
	pending_responses = [] 	:: [#presponse{}]
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(binary(), bitstring(), bitstring(), binary()) -> {ok, [#k1api_sms_status_dto{}]}.
get(CustomerUUID, UserID, SenderAddress, SendSmsRequestId) ->
	{ok, RequestID} = request_backend(CustomerUUID, UserID, SenderAddress, SendSmsRequestId),
	?log_debug("Successfully sent request [~p] to backend", [RequestID]),
	{ok, Response} = get_response(RequestID),
	{ok, Response#k1api_sms_delivery_status_response_dto.statuses}.

%% ===================================================================
%% GenServer Callbacks
%% ===================================================================

init([]) ->
	{ok, Connection} = rmql:connection_start(),
	{ok, Chan} = rmql:channel_open(Connection),
	link(Chan),
	ok = rmql:queue_declare(Chan, ?K1API_DELIVERY_STATUS_RESP_Q, []),
	ok = rmql:queue_declare(Chan, ?K1API_DELIVERY_STATUS_REQ_Q, []),
	NoAck = true,
	{ok, _ConsumerTag} = rmql:basic_consume(Chan, ?K1API_DELIVERY_STATUS_RESP_Q, NoAck),
	{ok, #state{chan = Chan}}.

handle_call(get_channel, _From, State = #state{chan = Chan}) ->
	{reply, {ok, Chan}, State};

handle_call({get_response, MesID}, From,
					State = #state{
								pending_workers = WList,
								pending_responses = RList}) ->
	Worker = #pworker{id = MesID, from = From, timestamp = k1api_lib:get_now()},
	{ok, NRList, NWList} = k1api_lib:process_worker_request(Worker, RList, WList),
	{noreply, State#state{pending_workers = NWList, pending_responses = NRList}};

handle_call(_Request, _From, State) ->
    {stop, unexpected_call, State}.

handle_cast(_Msg, State) ->
    {stop, unexpected_cast, State}.

handle_info({#'basic.deliver'{}, #amqp_msg{payload = Content}},
			 State = #state{
			 	pending_responses = ResponsesList,
				pending_workers = WorkersList}) ->
	?log_debug("Got sms delivery status response", []),
	case adto:decode(#k1api_sms_delivery_status_response_dto{}, Content) of
		{ok, Response = #k1api_sms_delivery_status_response_dto{
				id = CorrelationID }} ->
			?log_debug("Response was sucessfully decoded [id: ~p]", [CorrelationID]),
			NewPendingResponse = #presponse{id = CorrelationID, timestamp = k1api_lib:get_now(), response = Response},
			{ok, NRList, NWList} = k1api_lib:process_response(NewPendingResponse, ResponsesList, WorkersList),
			{noreply, State#state{pending_workers = NWList, pending_responses = NRList}};
		{error, Error} ->
			?log_error("Failed To Decode Response Due To ~p : ~p", [Error, Content]),
			{noreply, State}
	end;

handle_info(_Info, State) ->
    {stop, unexpected_info, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================

get_channel() ->
	gen_server:call(?MODULE, get_channel).

get_response(RequestUUID) ->
	gen_server:call(?MODULE, {get_response, RequestUUID}).

request_backend(CustomerUUID, UserID, SenderAddress, SendSmsRequestId) ->
 	{ok, Channel} = get_channel(),
	RequestUUID = uuid:unparse(uuid:generate()),
	DeliveryStatusReqDTO = #k1api_sms_delivery_status_request_dto{
		id = RequestUUID,
		customer_id = CustomerUUID,
		user_id = UserID,
		sms_request_id = SendSmsRequestId,
		address = k1api_lib:addr_to_dto(SenderAddress)
	},
	?log_debug("DeliveryStatusReqDTO: ~p", [DeliveryStatusReqDTO]),
	{ok, Payload} = adto:encode(DeliveryStatusReqDTO),
	Props = [{reply_to, ?K1API_DELIVERY_STATUS_RESP_Q}],
    ok = rmql:basic_publish(Channel, ?K1API_DELIVERY_STATUS_REQ_Q, Payload, Props),
	{ok, RequestUUID}.
