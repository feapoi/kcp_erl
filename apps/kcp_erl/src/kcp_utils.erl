%%%-------------------------------------------------------------------
%%% @author 100621
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. 7月 2021 15:56
%%%-------------------------------------------------------------------
-module(kcp_utils).
-author("100621").

-include("include/kcp.hrl").

%% API
-export([parse_ack/2, parse_fast_ack/3, ack_push/3, parse_una/3, shrink_buf/1, update_ack/2]).

%% 确认snd_buf（接收队列）中的数据是否存在已经确认但是未删除的seg，删除掉，空出空间
parse_ack(Kcp, Sn) ->
    %% 序号小于第一个未确认的包
    %% 序号大于等于下一个要发送的包
    case Sn < Kcp#kcp.snd_una orelse Sn >= Kcp#kcp.snd_nxt of
        true -> Kcp;
        _ ->
            Kcp#kcp{snd_buf = lists:keydelete(Sn, #segment.sn, Kcp#kcp.snd_buf)}
    end.

%% 更新快速确认数，判断snd_buf中，是否存在，sn小，ts也比较早的数据，进行快速确认，以便空出空间
parse_fast_ack(Kcp, Sn, Ts) ->
    %% 序号小于第一个未确认的包
    %% 序号大于等于下一个要发送的包
    case Sn < Kcp#kcp.snd_una orelse Sn >= Kcp#kcp.snd_nxt of
        true ->Kcp;
        _ ->
            NewSndBuf = loop_parse_fast_ack(Kcp#kcp.snd_buf, [], Sn, Ts),
            Kcp#kcp{snd_buf = NewSndBuf}
    end.
loop_parse_fast_ack([], Res, _Sn, _Ts) ->
    lists:reverse(Res);
loop_parse_fast_ack([Seg | SndBuf], Res, Sn, Ts) ->
    case Sn < Seg#segment.sn of
        true->
            lists:reverse(Res) ++ [Seg | SndBuf];
        _ ->
            case Sn =/= Seg#segment.sn andalso Seg#segment.ts =< Ts  of
                true ->
                    loop_parse_fast_ack(SndBuf, Res, Sn, [Seg#segment{fastack = Seg#segment.fastack + 1} | Ts]) ;
                _ ->
                    loop_parse_fast_ack(SndBuf, Res, Sn, [Seg | Ts])
            end
    end.

parse_una([], _Una, Count) ->
    {[], Count};
parse_una([Seg | SndBuf], Una, Count) ->
    case Una > Seg#segment.sn of
        true ->
            %% kcp.delSegment(seg),
            parse_una(SndBuf, Una, Count + 1) ;
        _ ->
            {[Seg | SndBuf], Count}
    end.

shrink_buf(Kcp) ->
    case erlang:byte_size(Kcp#kcp.snd_buf) > 0 of
        true ->
            [Seg | _] = Kcp#kcp.snd_buf,
            Kcp#kcp{snd_una = Seg#segment.una};
        _ ->
            Kcp#kcp{snd_una = Kcp#kcp.snd_nxt}
    end.

%% https://tools.ietf.org/html/rfc6298
update_ack(Kcp, Rtt) ->
    Kcp1 =
        case Kcp#kcp.rx_srtt == 0 of
            true ->
                Kcp#kcp{rx_srtt = Rtt, rx_rttvar = Rtt bsr 1};
            _ ->
                Delta = Rtt - Kcp#kcp.rx_srtt,
                Kcp01 = Kcp#kcp{rx_srtt = Kcp#kcp.rx_srtt + Delta bsr 3},
                Delta1 = ?IF(Delta < 0, -Delta, Delta),
                case Rtt < Kcp01#kcp.rx_srtt - Kcp#kcp.rx_rttvar of
                    %% if the new RTT sample is below the bottom of the range of
                    %% what an RTT measurement is expected to be.
                    %% give an 8x reduced weight versus its normal weighting
                    true -> Kcp01#kcp{rx_rttvar = Kcp01#kcp.rx_rttvar + (Delta1 - Kcp01#kcp.rx_rttvar) bsr 5};
                    _ -> Kcp01#kcp{rx_rttvar = Kcp01#kcp.rx_rttvar + (Delta1 - Kcp01#kcp.rx_rttvar) bsr 2}
                end
        end,
    Rto = Kcp1#kcp.rx_srtt + max(Kcp1#kcp.interval, Kcp1#kcp.rx_rttvar bsl 2),
    Kcp1#kcp{rx_rto = min(max(Kcp1#kcp.rx_minrto, Rto), ?IKCP_RTO_MAX)}.

ack_push(Kcp, Sn, Ts) ->
    Kcp#kcp{acklist = Kcp#kcp.acklist ++ [{Sn, Ts}]}.