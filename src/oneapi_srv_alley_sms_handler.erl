-module(oneapi_srv_alley_sms_handler).

-behaviour(oneapi_srv_gen_sms_handler).

-include("oneapi_srv.hrl").
-include("oneapi_srv_sms_handler_spec.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/utils.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_services/include/alley_services.hrl").

%% oneapi_srv_gen_sms_handler callbacks
-export([
    init/1,
    handle_send_outbound/2,
    handle_query_delivery_status/3,
    handle_subscribe_to_delivery_notifications/2,
    handle_unsubscribe_from_delivery_notifications/2,
    handle_retrieve_inbound/2,
    handle_subscribe_to_inbound_notifications/2,
    handle_unsubscribe_from_inbound_notifications/2
]).

-record(state, {
    creds :: term(),
    customer :: term()
}).

%% ===================================================================
%% oneapi_srv_gen_sms_handler callbacks
%% ===================================================================

init(Creds = #credentials{}) ->
    CustomerId = Creds#credentials.customer_id,
    UserId = Creds#credentials.user_id,
    Password = Creds#credentials.password,
    case alley_services_auth:authenticate(CustomerId, UserId, oneapi, Password) of
        {ok, #k1api_auth_response_dto{result = {customer, Customer}}} ->
            {ok, #state{creds = Creds, customer = Customer}};
        {ok, #k1api_auth_response_dto{result = {error, Error}}} ->
            ?log_error("Authenticate response error: ~p", [Error]),
            {error, authentication};
        {error, Error} ->
            ?log_error("Authenticate failed with: ~p", [Error]),
            {error, Error}
    end.

handle_send_outbound(#outbound_sms{notify_url = NotifyUrl} = Req, #state{
    customer = #k1api_auth_response_customer_dto{
        uuid = CustomerId,
        receipts_allowed = ReceiptsAllowed
    }
}) when (NotifyUrl =/= undefined andalso NotifyUrl =/= <<>>) andalso
        (not ReceiptsAllowed) ->
    ?log_debug("Got send outbound: ~p", [Req]),
    ?log_error("Delivery notifications are not allowed for customer_id: ~p",
        [CustomerId]),
    {error, receipts_not_allowed};
handle_send_outbound(Req, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got send outbound: ~p", [Req]),

    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId     = Creds#credentials.user_id,

    %% mandatory
    Recipients = oneapi_srv_utils:reformat_addrs(Req#outbound_sms.address),
    Originator = oneapi_srv_utils:reformat_addr(Req#outbound_sms.sender_address),
    Message    = Req#outbound_sms.message,

    %% optional
    Params = outbound_sms_optional_params(Req),

    SendReq = #send_req{
        action = send_sms,
        customer_id = CustomerId,
        user_id = UserId,
        client_type = oneapi,
        customer = Customer,
        recipients = Recipients,
        originator = Originator,
        text = Message,
        flash = false,
        smpp_params = Params
    },
    {ok, Result} = alley_services_mt:send(SendReq),
    ?log_debug("Got submit result: ~p", [Result]),

    case Result#send_result.result of
        ok ->
            {ok, Result#send_result.req_id};
        Error ->
            ?log_error("Send outbound failed with: ~p", [Error]),
            {error, Error}
    end.

handle_query_delivery_status(_SenderAddr, _ReqId, #state{
    customer = #k1api_auth_response_customer_dto{
        uuid = CustomerId,
        receipts_allowed = false
    }
}) ->
    ?log_debug("Got query delivery status (customer_id: ~p)", [CustomerId]),
    ?log_error("Delivery notifications are not allowed for customer_id: ~p", [CustomerId]),
    {error, receipts_not_allowed};
handle_query_delivery_status(SenderAddr, ReqId, #state{
    creds = Creds,
    customer = Customer
}) ->
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,

    ?log_debug("Got query delivery status "
        "(customer_id: ~p, user_id: ~p, sender_addr: ~p, req_id: ~p)",
        [CustomerId, UserId, SenderAddr, ReqId]),

    SenderAddr2 = alley_services_utils:addr_to_dto(SenderAddr),
    case alley_services_api:get_delivery_status(
            CustomerId, UserId, ReqId, SenderAddr2) of
        {ok, Response} ->
            Statuses = Response#k1api_sms_delivery_status_response_dto.statuses,
            DeliveryStatuses = convert_delivery_statuses(Statuses),
            {ok, DeliveryStatuses};
        {error, Error} ->
            ?log_error("Query delivery status failed with: ~p", [Error]),
            {error, Error}
    end.

handle_subscribe_to_delivery_notifications(Req, #state{
    customer = #k1api_auth_response_customer_dto{
        uuid = CustomerId,
        receipts_allowed = false
    }
}) ->
    ?log_debug("Got subscribe to delivery notifications: ~p", [Req]),
    ?log_error("Delivery notifications are not allowed for customer_id: ~p", [CustomerId]),
    {error, receipts_not_allowed};
handle_subscribe_to_delivery_notifications(Req, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got subscribe to delivery notifications: ~p", [Req]),
    #subscribe_delivery_notifications{
        notify_url = NotifyUrl,
        client_correlator = ClientCorrelator,
        criteria = _Criteria,
        callback_data = CallbackData,
        sender_addr = SenderAddr
    } = Req,
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,
    ReqId = uuid:unparse(uuid:generate()),
    case oneapi_srv_db:write_correlator(CustomerId, UserId, ClientCorrelator, ReqId) of
        ok ->
            ?log_debug("Correlator saved", []),
            SourceAddr = #addr{addr = SenderAddr, ton = 1, npi = 1},
            case alley_services_api:subscribe_sms_receipts(
                    ReqId, CustomerId, UserId, NotifyUrl, SourceAddr, CallbackData) of
                {ok, _Response} ->
                    {ok, ReqId};
                {error, Error} ->
                    ?log_error("Subscribe to delivery notifications failed with: ~p", [Error]),
                    ok = oneapi_srv_db:delete_correlator(CustomerId, UserId, ClientCorrelator),
                    ?log_debug("Correlator deleted", []),
                    {error, Error}
            end;
        {error, {already_exists, OrigReqId}} ->
            ?log_debug("Correlator already exists: ~p", [OrigReqId]),
            {error, already_exists}
    end.

handle_unsubscribe_from_delivery_notifications(SubId, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got unsubscribe from delivery notifications: ~p", [SubId]),
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,
    ReqId = uuid:unparse(uuid:generate()),
    case alley_services_api:unsubscribe_sms_receipts(
            ReqId, CustomerId, UserId, SubId) of
        {ok, _Resp} ->
            ?log_debug("Delivery sub (id: ~p) removed", [SubId]),
            {ok, deleted};
        {error, Error} ->
            ?log_error("Unsubscribe from delivery notifications failed with: ~p", [Error]),
            {error, Error}
    end.

handle_retrieve_inbound(Req, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got retrieve inboud: ~p", [Req]),
    #retrieve_sms_req{
        reg_id = RegId,
        batch_size = BatchSize
    } = Req,
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,

    %% !!! registrationID agreed with the OneAPI operator !!!
    %% !!! We use Sender Address for this !!!
    DestAddr = alley_services_utils:addr_to_dto(RegId),

    case alley_services_api:retrieve_sms(CustomerId, UserId, DestAddr, BatchSize) of
        {ok, #k1api_retrieve_sms_response_dto{
            messages = MessagesDTO,
            total = Total
        }} ->
            Messages = lists:map(
                fun(MessageDTO) ->
                    #k1api_retrieved_sms_dto{
                        datetime = {MegaSecs, Secs, _MicroSecs},
                        sender_addr = SenderAddr,
                        message_id = MsgId,
                        message = Message
                    } = MessageDTO,
                    UnixEpochDateTime = MegaSecs * 1000000 + Secs,
                    #inbound_sms{
                        date_time = ac_datetime:unixepoch_to_datetime(UnixEpochDateTime),
                        message_id = MsgId,
                        message = Message,
                        sender_addr = SenderAddr#addr.addr
                    }
                 end, MessagesDTO),
            ?log_debug("Retrieved messages: ~p", [Messages]),
            {ok, Messages, Total};
        {error, Error} ->
            ?log_error("Retrieve inbound failed with: ~p", [Error]),
            {error, Error}
    end.

handle_subscribe_to_inbound_notifications(Req, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got subscribe to inbound notifications: ~p", [Req]),
    #subscribe_inbound{
        dest_addr = DestAddr,
        notify_url = NotifyURL,
        criteria = Criteria,
        callback_data = CallbackData,
        correlator = Correlator
    } = Req,
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,
    ReqId = uuid:unparse(uuid:generate()),
    case oneapi_srv_db:write_correlator(CustomerId, UserId, Correlator, ReqId) of
        ok ->
            ?log_debug("Correlator saved", []),
            DestAddr2 = #addr{addr = DestAddr, ton = 1, npi = 1},
            case alley_services_api:subscribe_incoming_sms(
                    ReqId, CustomerId, UserId, DestAddr2,
                    NotifyURL, Criteria, Correlator, CallbackData) of
                {ok, _Response} ->
                    {ok, ReqId};
                {error, Error} ->
                    ?log_error("Subscribe to inbound notifications failed with: ~p", [Error]),
                    ok = oneapi_srv_db:delete_correlator(CustomerId, UserId, Correlator),
                    ?log_debug("Correlator deleted", []),
                    {error, Error}
            end;
        {error, {already_exists, OrigReqId}} ->
            ?log_debug("Correlator already exists: ~p", [OrigReqId]),
            {error, already_exists}
    end.

handle_unsubscribe_from_inbound_notifications(SubId, #state{
    creds = Creds,
    customer = Customer
}) ->
    ?log_debug("Got unsubscribe from inbound notifications: ~p", [SubId]),
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId = Creds#credentials.user_id,
    ReqId = uuid:unparse(uuid:generate()),
    case alley_services_api:unsubscribe_incoming_sms(
            ReqId, CustomerId, UserId, SubId) of
        {ok, _Resp} ->
            ?log_debug("Inbound sub (id: ~p) removed", [SubId]),
            {ok, deleted};
        {error, Error} ->
            ?log_error("Unsubscribe from inbound notifications failed with: ~p", [Error]),
            {error, Error}
    end.

%% ===================================================================
%% Internal
%% ===================================================================

outbound_sms_optional_params(OutboundSms = #outbound_sms{}) ->
    Fun =
        fun({Name, Index}, Acc) ->
            case element(Index, OutboundSms) of
                undefined ->
                    Acc;
                Value ->
                    [{Name, Value} | Acc]
            end
        end,
    Params = [{<<"oneapi_client_correlator">>, #outbound_sms.client_correlator},
              {<<"oneapi_notify_url">>, #outbound_sms.notify_url},
              {<<"oneapi_callback_data">>, #outbound_sms.callback_data}],
    lists:foldl(Fun, [], Params).

convert_delivery_statuses(#k1api_sms_status_dto{
    address = Addr, status = Status
}) ->
    {Addr#addr.addr, oneapi_srv_utils:translate_status_name(Status)};
convert_delivery_statuses(Statuses) ->
    [convert_delivery_statuses(Status) || Status <- Statuses].
