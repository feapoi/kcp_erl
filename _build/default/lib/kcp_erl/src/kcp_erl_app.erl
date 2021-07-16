%%%-------------------------------------------------------------------
%% @doc kcp_erl public API
%% @end
%%%-------------------------------------------------------------------

-module(kcp_erl_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    kcp_erl_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
