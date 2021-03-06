-module(cds_card_v1_thrift_handler).
-behaviour(woody_server_thrift_handler).

-include_lib("damsel/include/dmsl_cds_thrift.hrl").

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%%
%% woody_server_thrift_handler callbacks
%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().

handle_function(OperationID, Args, Context, Opts) ->
    scoper:scope(
        card_data,
        cds_thrift_handler_utils:filter_fun_exceptions(fun() -> handle_function_(OperationID, Args, Context, Opts) end)
    ).

handle_function_('GetSessionCardData', [Token, Session], _Context, _Opts) ->
    try
        {DecodedToken, DecodedPayload} = cds_utils:decode_token_with_payload(Token),
        CardData = maps:merge(
            get_cardholder_data(DecodedToken),
            DecodedPayload
        ),
        SessionData = try_get_session_data(Session),
        {ok, encode_card_data(CardData, SessionData)}
    catch
        not_found ->
            cds_thrift_handler_utils:raise(#'CardDataNotFound'{});
        no_keyring ->
            cds_thrift_handler_utils:raise_keyring_unavailable()
    end;

handle_function_('PutCard', [CardData], _Context, _Opts) ->
    OwnCardData = decode_card_data(CardData),
    try
        case cds_card_data:validate(OwnCardData) of
            {ok, CardInfo} ->
                Token = put_card(OwnCardData),
                ExpDate = maps:get(exp_date, OwnCardData, undefined),
                Payload = maps:without([cardnumber], OwnCardData),
                BankCard = #'domain_BankCard'{
                    token          = cds_utils:encode_token_with_payload(Token, Payload),
                    payment_system = maps:get(payment_system, CardInfo),
                    bin            = maps:get(iin           , CardInfo),
                    last_digits    = maps:get(last_digits   , CardInfo),
                    exp_date       = encode_exp_date(ExpDate),
                    cardholder_name = maps:get(cardholder, OwnCardData, undefined)
                },
                {ok, #'PutCardResult'{
                    bank_card = BankCard
                }};
            {error, ValidationError} ->
                cds_thrift_handler_utils:raise(#'InvalidCardData'{
                    reason = cds_thrift_handler_utils:map_validation_error(ValidationError)
                })
        end
    catch
        no_keyring ->
            cds_thrift_handler_utils:raise_keyring_unavailable()
    end;

handle_function_('GetCardData', [Token], _Context, _Opts) ->
    try
        {DecodedToken, DecodedPayload} = cds_utils:decode_token_with_payload(Token),
        CardData = maps:merge(
            get_cardholder_data(DecodedToken),
            DecodedPayload
        ),
        {ok, encode_cardholder_data(CardData)}
    catch
        not_found ->
            cds_thrift_handler_utils:raise(#'CardDataNotFound'{});
        no_keyring ->
            cds_thrift_handler_utils:raise_keyring_unavailable()
    end;

handle_function_('PutSession', [Session, SessionData], _Context, _Opts) ->
    OwnSessionData = decode_session_data(SessionData),
    try
        ok = put_session(Session, OwnSessionData),
        {ok, ok}
    catch
        no_keyring ->
            cds_thrift_handler_utils:raise_keyring_unavailable()
    end;

handle_function_('GetSessionData', [Session], _Context, _Opts) ->
    try
        SessionData = try_get_session_data(Session),
        {ok, encode_session_data(SessionData)}
    catch
        not_found ->
            cds_thrift_handler_utils:raise(#'SessionDataNotFound'{});
        no_keyring ->
            cds_thrift_handler_utils:raise_keyring_unavailable()
    end.

%%
%% Internals
%%

decode_card_data(#'CardData'{
    pan             = PAN,
    exp_date        = #'ExpDate'{month = Month, year = Year},
    cardholder_name = CardholderName
}) ->
    #{
        cardnumber => PAN,
        exp_date   => {Month, Year},
        cardholder => CardholderName
    }.

decode_session_data(#'SessionData'{auth_data = AuthData}) ->
    #{auth_data => decode_auth_data(AuthData)}.

decode_auth_data({card_security_code, #'CardSecurityCode'{value = Value}}) ->
    #{type => cvv, value => Value};
decode_auth_data({auth_3ds, #'Auth3DS'{cryptogram = Cryptogram, eci = ECI}}) ->
    genlib_map:compact(#{type => '3ds', cryptogram => Cryptogram, eci => ECI}).

encode_card_data(CardData, #{auth_data := AuthData}) ->
    V = encode_cardholder_data(CardData),
    case maps:get(type, AuthData) of
        cvv ->
            V#'CardData'{cvv = maps:get(value, AuthData)};
        '3ds' ->
            V
    end.

encode_cardholder_data(#{
    cardnumber := PAN,
    exp_date   := {Month, Year}
} = Data) ->
    CardholderName = maps:get(cardholder, Data, undefined),
    #'CardData'{
        pan             = PAN,
        exp_date        = #'ExpDate'{month = Month, year = Year},
        cardholder_name = CardholderName,
        cvv             = <<>>
    }.

encode_session_data(#{auth_data := AuthData}) ->
    #'SessionData'{auth_data = encode_auth_data(AuthData)}.

encode_auth_data(#{type := cvv, value := Value}) ->
    {card_security_code, #'CardSecurityCode'{value = Value}};
encode_auth_data(#{type := '3ds', cryptogram := Cryptogram} = Data) ->
    ECI = genlib_map:get(eci, Data),
    {auth_3ds, #'Auth3DS'{cryptogram = Cryptogram, eci = ECI}}.

%

get_cardholder_data(Token) ->
    {_, CardholderData} = cds:get_cardholder_data(Token),
    cds_card_data:unmarshal_cardholder_data(CardholderData).

put_card(CardholderData) ->
    cds:put_card(cds_card_data:marshal_cardholder_data(CardholderData)).

put_session(Session, SessionData) ->
    cds:put_session(Session, cds_card_data:marshal_session_data(SessionData)).

get_session_data(Session) ->
    {_, SessionData} = cds:get_session_data(Session),
    cds_card_data:unmarshal_session_data(SessionData).

try_get_session_data(Session0) ->
    try
        Session = cds_utils:decode_session(Session0),
        get_session_data(Session)
    catch
        error:badarg -> % could not decode SessionID, let's try new scheme
            get_session_data(Session0);
        not_found -> % same as before but for false positive decoding case
            get_session_data(Session0)
    end.

encode_exp_date(undefined) ->
    undefined;
encode_exp_date({Month, Year}) ->
    #domain_BankCardExpDate{
        month = Month,
        year = Year
    }.
