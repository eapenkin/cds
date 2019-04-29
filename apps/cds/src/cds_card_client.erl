-module(cds_card_client).

-include_lib("dmsl/include/dmsl_cds_thrift.hrl").
-include_lib("dmsl/include/dmsl_domain_thrift.hrl").

-export([get_card_data/2]).
-export([get_session_card_data/3]).
-export([put_card_data/2]).
-export([put_card_data/3]).
-export([get_session_data/2]).
-export([put_card/2]).
-export([put_session/3]).

%%
%% Internal types
%%

-type result() :: cds_woody_client:result().
-type card_data() :: dmsl_cds_thrift:'CardData'().
-type session_data() :: dmsl_cds_thrift:'SessionData'() | undefined.

%%
%% API
%%

-spec get_card_data(cds:token(), woody:url()) -> result().
get_card_data(Token, RootUrl) ->
    try cds_woody_client:call(card, 'GetCardData', [Token], RootUrl) of
        EncodedCardData ->
            decode_card_data(EncodedCardData)
    catch
        #'CardDataNotFound'{} ->
            {error, card_data_not_found}
    end.

-spec get_session_card_data(cds:token(), cds:session(), woody:url()) -> result().
get_session_card_data(Token, Session, RootUrl) ->
    try cds_woody_client:call(card, 'GetSessionCardData', [Token, Session], RootUrl) of
        EncodedCardData ->
            decode_card_data(EncodedCardData)
    catch
        #'CardDataNotFound'{} ->
            {error, card_data_not_found}
    end.

-spec put_card_data(card_data(), woody:url()) -> result().
put_card_data(CardData, RootUrl) ->
    put_card_data(CardData, undefined, RootUrl).

-spec put_card_data(card_data(), session_data(), woody:url()) -> result().
put_card_data(CardData, SessionData, RootUrl) ->
    try cds_woody_client:call(card, 'PutCardData',
        [encode_card_data(CardData), encode_session_data(SessionData)], RootUrl) of
        #'PutCardDataResult'{bank_card = BankCard, session_id = PaymentSessionId} ->
            #{
                bank_card => decode_bank_card(BankCard),
                session_id => PaymentSessionId
            }
    catch
        #'InvalidCardData'{reason = Reason} ->
            {error, {invalid_catd_data, Reason}}
    end.

-spec get_session_data(cds:session(), woody:url()) -> result().
get_session_data(Session, RootUrl) ->
    try cds_woody_client:call(card, 'GetSessionData', [Session], RootUrl) of
        SessionData ->
            decode_session_data(SessionData)
    catch
        #'SessionDataNotFound'{} ->
            {error, session_data_not_found}
    end.

-spec put_card(card_data(), woody:url()) -> result().
put_card(CardData, RootUrl) ->
    try cds_woody_client:call(card, 'PutCard', [encode_card_data(CardData)], RootUrl) of
        #'PutCardResult'{bank_card = BankCard} ->
            #{
                bank_card => decode_bank_card(BankCard)
            }
    catch
        #'InvalidCardData'{reason = Reason} ->
            {error, {invalid_catd_data, Reason}}
    end.

-spec put_session(cds:session(), session_data(), woody:url()) -> result().
put_session(SessionID, SessionData, RootUrl) ->
    cds_woody_client:call(card, 'PutSession', [SessionID, encode_session_data(SessionData)], RootUrl).

encode_card_data(
    #{
        pan := Pan,
        exp_date := #{
            month := ExpDateMonth,
            year := ExpDateYear
        },
        cardholder_name := CardHolderName,
        cvv := CVV
    }) ->
    #'CardData'{
        pan = Pan,
        exp_date = #'ExpDate'{
            month = ExpDateMonth,
            year = ExpDateYear
        },
        cardholder_name = CardHolderName,
        cvv = CVV
    };
encode_card_data(
    #{
        pan := Pan,
        exp_date := #{
            month := ExpDateMonth,
            year := ExpDateYear
        }
    }) ->
    #'CardData'{
        pan = Pan,
        exp_date = #'ExpDate'{
            month = ExpDateMonth,
            year = ExpDateYear
        }
    }.

encode_session_data(undefined) -> undefined;
encode_session_data(
    #{
        auth_data := {auth_3ds, #{
            cryptogram := Cryptogram,
            eci := Eci
        }}
    }) ->
    #'SessionData'{
        auth_data = {auth_3ds, #'Auth3DS'{
            cryptogram = Cryptogram,
            eci = Eci
        }}
    };
encode_session_data(
    #{
        auth_data := {card_security_code, #{
            value := Value
        }}
    }) ->
    #'SessionData'{
        auth_data = {card_security_code, #'CardSecurityCode'{
            value = Value
        }}
    }.

decode_bank_card(
    #'domain_BankCard'{
        token = Token,
        payment_system = PaymentSystem,
        bin = Bin,
        masked_pan = MaskedPan,
        token_provider = TokenProvider,
        issuer_country = IssuerCountry,
        bank_name = BankName,
        metadata = Metadata,
        is_cvv_empty = IsCVVEmpty
    }) ->
    #{
        token => Token,
        payment_system => PaymentSystem,
        bin => Bin,
        masked_pan => MaskedPan,
        token_provider => TokenProvider,
        issuer_country => IssuerCountry,
        bank_name => BankName,
        metadata => Metadata,
        is_cvv_empty => IsCVVEmpty
    }.

decode_card_data(
    #'CardData'{
        pan = Pan,
        exp_date = #'ExpDate'{
            month = ExpDateMonth,
            year = ExpDateYear
        },
        cardholder_name = CardHolderName,
        cvv = CVV
    }) ->
    #{
        pan => Pan,
        exp_date => #{
            month => ExpDateMonth,
            year => ExpDateYear
        },
        cardholder_name => CardHolderName,
        cvv => CVV
    }.

decode_session_data(
    #'SessionData'{
        auth_data = {auth_3ds, #'Auth3DS'{
            cryptogram = Cryptogram,
            eci = Eci
        }}
    }) ->
    #{
        auth_data => {auth_3ds, #{
            cryptogram => Cryptogram,
            eci => Eci
        }}
    };
decode_session_data(
    #'SessionData'{
        auth_data = {card_security_code, #'CardSecurityCode'{
            value = Value
        }}
    }) ->
    #{
        auth_data => {card_security_code, #{
            value => Value
        }}
    }.