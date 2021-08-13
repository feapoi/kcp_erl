%%%-------------------------------------------------------------------
%%% @author 100621
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 13. 8月 2021 15:09
%%%-------------------------------------------------------------------
-module(kcp).
-author("100621").

%% API
-export([start/2]).

start(Port1, Port2) ->
    supervisor:start_child(kcp_erl_sup,[Port1]),
    supervisor:start_child(kcp_erl_sup,[Port2]),
    gen_server:cast(kcp_utils:name(Port1), {set_host_and_port, "127.0.0.1", Port2}),
    gen_server:cast(kcp_utils:name(Port2), {set_host_and_port, "127.0.0.1", Port1}),
    gen_server:cast(kcp_utils:name(Port1), start_loop),
    gen_server:cast(kcp_utils:name(Port2), start_loop).
