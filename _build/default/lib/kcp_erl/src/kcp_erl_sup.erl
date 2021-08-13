%%%-------------------------------------------------------------------
%% @doc kcp_erl top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(kcp_erl_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    Procs = [{kcp_server, {kcp_server, start_link,[]},temporary, brutal_kill, worker,[]}],
    {ok, {{simple_one_for_one, 5, 5000}, Procs}}.

%% internal functions
