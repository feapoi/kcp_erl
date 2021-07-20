%%%-------------------------------------------------------------------
%%% @author 100621
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(kcp).

-behaviour(gen_server).

%%/**
%% * 引用：https://blog.csdn.net/lixiaowei16/article/details/90485157
%% * 		http://vearne.cc/archives/39317
%% * 		https://github.com/shaoyuan1943/gokcp/blob/master/kcp.go
%% *		https://github.com/xtaci/kcp-go
%% *
%% * 0               4   5   6       8 (BYTE)
%% * +---------------+---+---+-------+
%% * |     conv      |cmd|frg|  wnd  |
%% * +---------------+---+---+-------+   8
%% * |     ts        |     sn        |
%% * +---------------+---------------+  16
%% * |     una       |     len       |
%% * +---------------+---------------+  24
%% * |                               |
%% * |        DATA (optional)        |
%% * |                               |
%% * +-------------------------------+
%% * conv:连接号。UDP是无连接的，conv用于表示来自于哪个客户端。对连接的一种替代, 因为有conv, 所以KCP也是支持多路复用的
%% * cmd:命令类型，只有四种:
%% * 				CMD四种类型
%% *                     ----------------------------------------------------------------------------------
%% * 					   |cmd 			|作用 					|备注                    				|
%% *                     ----------------------------------------------------------------------------------
%% * 					   |IKCP_CMD_PUSH 	|数据推送命令            |与IKCP_CMD_ACK对应      				|
%% *                     ----------------------------------------------------------------------------------
%% * 					   |IKCP_CMD_ACK 	|确认命令                |1、RTO更新，2、确认发送包接收方已接收到	|
%% *                     ----------------------------------------------------------------------------------
%% * 					   |IKCP_CMD_WASK 	|接收窗口大小询问命令     |与IKCP_CMD_WINS对应      				|
%% *                     ----------------------------------------------------------------------------------
%% * 					   |IKCP_CMD_WINS 	|接收窗口大小告知命令     |                        				|
%% *                     ----------------------------------------------------------------------------------
%% * frg:分片，用户数据可能会被分成多个KCP包，发送出去
%% * wnd:接收窗口大小，发送方的发送窗口不能超过接收方给出的数值
%% * ts: 时间序列
%% * sn: 序列号
%% * una:下一个可接收的序列号。其实就是确认号，收到sn=10的包，una为11
%% * len:数据长度(DATA的长度)
%% * data:用户数据
%% *
%% * KCP流程说明
%% * 1. 判定是消息模式还是流模式
%% * 		1.1 消息模式(不拆包): 对应传输--文本消息
%% * 			KCP header        KCP DATA
%% *       -----------------------------------------------------------------------------------------------------------------------
%% *       |  sn  |  90  |  --------------------  |  sn  |  91  |  --------------------  |  sn  |  92  |  --------------------   |
%% *       |  frg |  0   |  |       MSG1       |  |  frg |  0   |  |       MSG2       |  |  frg |  0   |  |       MSG3       |   |
%% *       |  len |  15  |  --------------------  |  sn  |  20  |  --------------------  |  sn  |  18  |  --------------------   |
%% *       -----------------------------------------------------------------------------------------------------------------------
%% * 		1.2 消息模式(拆包；拆包原则：根据MTU(最大传输单元决定))：对应传输--图片或文件消息
%% * 			KCP header        KCP DATA
%% *       -----------------------------------------------------------------------------------------------------------------------
%% *       |  sn  |  90  |  --------------------  |  sn  |  91  |  --------------------  |  sn  |  92  |  --------------------   |
%% *       |  frg |  2   |  |      MSG4-1      |  |  frg |  1   |  |      MSG4-2      |  |  frg |  0   |  |      MSG4-3      |   |
%% *       |  len | 1376 |  --------------------  |  sn  | 1376 |  --------------------  |  sn  |  500 |  --------------------   |
%% *       -----------------------------------------------------------------------------------------------------------------------
%% * 		Msg被拆成了3部分，包含在3个KCP包中。注意, frg的序号是从大到小的，一直到0为止。这样接收端收到KCP包时，只有拿到frg为0的包，才会进行组装并交付给上层应用程序。
%% *         由于frg在header中占1个字节，也就是最大能支持（1400 – 24[所有头的长度]） * 256 / 1024 = 344kB的消息
%% * 		1.3 流模式
%% * 			KCP header        KCP DATA
%% *       ---------------------------------------------------------------------------------
%% *       |  sn  |  90  |  -------  ------  --------  |  sn  |  91  |  --------------------
%% *       |  frg |  0   |  | MSG1| | MSG2| | MSG3-1|  |  frg |  0   |  |       MSG3-2     |
%% *       |  len | 1376 |  ------  ------  ---------  |  sn  |  53  |  --------------------
%% *       ---------------------------------------------------------------------------------
%% *      1.4 消息模式与流模式对比
%% * 			1.4.1 消息模式：	减少了上层应用拆分数据流的麻烦，但是对网络的利用率较低。Payload(有效载荷)少，KCP头占比过大。
%% * 			1.4.2 流模式：	KCP试图让每个KCP包尽可能装满。一个KCP包中可能包含多个消息。但是上层应用需要自己来判断每个消息的边界。
%% * 2. 根据不同模式，得到需要传输的数据片段(segment)
%% * 3. 数据片段在发送端会存储在snd_queue中
%% * -----------------进入发送、传输、接收阶段------------------------------------------------------------------
%% * 		-------------------------									-------------------------
%% * 		|	Sender				|									|	Receiver			|
%% * 		|		 ------------	|									|		 ------------	|
%% *		|		|	APP		|	|									|		|	APP		|	|
%% *		|		------------	|									|		------------	|
%% *		|		    \|/		|										|		    /|\			|
%% * 		|		------------	|									|		------------	|
%% *		|		|  send buf	|---|--------------- LINK --------------|----->	|receive buf|	|
%% *		|		------------	|									|		------------	|
%% * 		-------------------------									-------------------------
%% * 		此过程中的三个阶段分别对应一个容量(发送阶段：IKCP_WND_SND，传输阶段：cwnd，接受阶段：IKCP_WND_RCV)
%% * 		cwnd剩余容量：snd_nxt(计划要发送的下一个segment号)-snd_una(接受端已经确认的最大连续接受号)=LINK中途在传输的数据量
%% * 4. 需要发送的时候，会将数据转移到snd_buf；但是snd_buf大小是有限的，所以在转移之前需要判定snd_buf的大小
%% *		4.1 snd_buf未满：将snd_queue的数据块flush到snd_buf，知道snd_queue清空或snd_buf已满停止
%% * 		4.2 snd_buf已满、cwnd未满: 将snd_buf的数据send出去，然后将snd_queue写入snd_buf
%% * 		4.3 snd_buf已满、cwnd已满: 不在写入，通过一个定时器定时判断cwnd是否有剩余流量，如果存在，完成第二步操作
%% * 		4.4 其他情况：
%% * 			4.4.1 如果snd_queue已满，snd_buf已满，cwnd已满，数据依然会直接flush，如果失败，即算超时处理
%% *			4.4.2 如果NoDelay=false，就不在写入snd_buf
%% * 5. LINK: 回调UDP的send进行传输(kcp->output=udp_output)
%% * 6. 接受数据:
%% * 		6.1 数据发送给接受端，接受端通过input进行接受，并解包receive buf，有确认的数据包recv_buf-->recv_queue
%% *		6.2 获取完整用户数据：从receive queue中进行拼装完整用户数据
%% */

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-include("include/kcp.hrl").

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    {ok, #kcp{}}.

handle_call(_Request, _From, State = #kcp{}) ->
    {reply, ok, State}.

handle_cast({recv, Buffer}, Kcp) ->
    try

        {noreply, Kcp}
    catch
        throw:_ ->
            {noreply, Kcp}
    end;
handle_cast(_Request, State = #kcp{}) ->
    {noreply, State}.

handle_info(_Info, State = #kcp{}) ->
    {noreply, State}.

terminate(_Reason, _State = #kcp{}) ->
    ok.

code_change(_OldVsn, State = #kcp{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%======================================================================================================================
%% Send
%%======================================================================================================================
%%// Send is user/upper level send, returns below zero for error
%%// 3. Send 数据格式化--> Segment
%%// * 1. 先判断消息类型；如果是流模式，则判断是否与现有Segment合并
%%// * 2. 如果是消息模式，则创建新Segment
send(Kcp, <<>>) -> %% 如果数据为空，直接退出
    {Kcp, -1}.
send(Kcp, Buffer) ->
    %% append to previous segment in streaming mode (if possible)
    %% 如果是流模式，则判断是否与现有Segment合并
    SndQueue = Kcp#kcp.snd_queue,
    case Kcp#kcp.stream of
        0 ->
            add_buff_2_seg(byte_size(Buffer), Kcp, Buffer, SndQueue);
        _ ->
            N = erlang:length(SndQueue),
            {SndQueue1, Buffer1} =
                %% 判断是否有未发送的消息
                %% 此处只判定snd_queue，因为snd_buf中可能是已经发送，只不过未确认而没有删除的记录
                case N > 0 of
                    true ->
                        [Seg | SndQueue0] = SndQueue,  %% 将最后一条记录取出
                        DataLen = erlang:byte_size(Seg#segment.data),
                        BufferLen = erlang:byte_size(Buffer),
                        %% 如果还有剩余空间
                        case DataLen < Kcp#kcp.mss of
                            true ->
                                Capacity = Kcp#kcp.mss - DataLen,   %% 获取剩余空间
                                Extend = ?IF(BufferLen < Capacity, BufferLen, Capacity),    %% 初始化扩展大小，默认是全部占用，如果新数据小于剩余空间，则设置扩展大小为新数据长度

                                %% grow slice, the underlying cap is guaranteed to
                                %% be larger than kcp.mss
                                <<Add2Seg:Extend, OtherBuffer/bytes>> = Buffer,
                                {[Seg#segment{data = <<(Seg#segment.data)/bytes, Add2Seg/bytes>>} | SndQueue0], OtherBuffer};
                            _ ->
                                {SndQueue, Buffer}
                        end;
                    _ ->
                        {SndQueue, Buffer}
                end,
            %% 如果buffer剩余的内容长度为0，表示已经完成数据的写入Segment的过程，结束
            case erlang:byte_size(Buffer1) of
                0 ->
                    %% return 0
                    {Kcp, 0};
                BufferLen1 ->
                    add_buff_2_seg(BufferLen1, Kcp, Buffer1, SndQueue1)
            end
    end.

%% 把所有的buffer放入snd_queue
add_buff_2_seg(BufferLen1, Kcp, Buffer1, SndQueue1) ->
    Count =
        %% 以下说明中，无论是已经合并一部分到上一个Segment还是没有合并的情况，统统称呼为新数据
        %% 如果新数据小于一个新Segment的数据长度
        case BufferLen1 =< Kcp#kcp.mss of
            true ->
                1;
            _ ->
                (BufferLen1 + Kcp#kcp.mss - 1) div Kcp#kcp.mss
        end,
        %% 如果新增加的输入大于255个，直接表示无法发送  254*(1400-24)/1024=344KB的数据
        %% 想要多发数据，只能通过MTU进行设定
        case Count > 255 of
            %% return 2
            true -> {Kcp, -2};
            _ ->
                Count1 = ?IF(Count == 0, 1, Count),
                %% 遍历Segment数量
                {_Buffer2, SndQueue2} = loop_seg(0, Count1, BufferLen1, Buffer1, Kcp, SndQueue1),
                {Kcp#kcp{snd_queue = SndQueue2}, 0}
        end.

loop_seg(I, Count, _BufferLen, Buffer, _Kcp, SndQueueReverse) when I + 1 >= Count ->
    {Buffer, SndQueueReverse};
loop_seg(I, Count, BufferLen, Buffer, Kcp, SndQueueReverse) ->
    %% 判断剩余的buffer长度是否还是大于Segment存放数据的空间
    Size  = min(BufferLen, Kcp#kcp.mss),
    %% init seg
    %% 创建Segment
    %% todo
    Seg = #segment{},
    <<Add:Size, OtherBuffer/bytes>> = Buffer,
    Seg1 = Seg#segment{
        %% 将数据存放到新的Segment中
        data = Add
        %% message mode 如果是消息模式，则需要将frg标记号码，从大到小,stream mode	如果是流模式，就不需要
        ,frg = ?IF(Kcp#kcp.stream == 0, Count - I - 1, 0)
    },
    %% 将Segment存放到snd_queue中去
    SndQueueReverse1 = [Seg1 | SndQueueReverse],
    loop_seg(I + 1, Count, BufferLen - Size, OtherBuffer, Kcp, SndQueueReverse1).
%%======================================================================================================================




%%======================================================================================================================
%% Flush
%%======================================================================================================================
%%/**
%% * 4. 需要发送的时候，会将数据转移到snd_buf；但是snd_buf大小是有限的，所以在转移之前需要判定snd_buf的大小
%% * ackOnly=true  更新acklist(待发送列表)
%% * ackOnly=false 更新acklist(待发送列表), 将snd_queue移动到snd_buf，确认重传数据及时间
%% * 通过kcp.output:发送数据
%% */
flush(Kcp, AckOnly) ->
    Seg = #segment{
        conv = Kcp#kcp.conv
        ,cmd = ?IKCP_CMD_ACK
        ,wnd = wnd_unused(Kcp)
        ,una = Kcp#kcp.rcv_nxt
    },
    Mtu = Kcp#kcp.mtu,
    {Seg0, Ptr1} = flush_acknowledges(Kcp#kcp.acklist, Kcp, Seg, <<>>),
    Kcp1 = Kcp#kcp{acklist = []},

    %% 仅仅更新acklist
    case AckOnly of
        true ->
            flush_buffer(Ptr1), %% flash remain ack segments
            {Kcp1, Kcp1#kcp.interval};
        _ ->
            %% probe window size (if remote window size equals zero)
            Kcp2 =
                case Kcp1#kcp.rmt_wnd == 0 of %% 如果远程端口尺寸==0
                    true ->
                        Current = ?CURRENT,
                        case Kcp1#kcp.probe_wait == 0 of %% 如果探查等待时间也没有设定
                            true ->
                                Kcp1#kcp{
                                    probe_wait = ?IKCP_PROBE_INIT   %% 则7s后进行窗口尺寸探查
                                    ,ts_probe = Current + Kcp1#kcp.probe_wait   %% 探查时间为当前时间+7s
                                };
                            _ ->
                                case Current - Kcp1#kcp.ts_probe >= 0 of    %% 判断当前时间已经到达窗口探查时间
                                    true ->
                                        Kcp11 = ?IF(Kcp1#kcp.probe_wait < ?IKCP_PROBE_INIT, Kcp1#kcp{probe_wait = ?IKCP_PROBE_INIT}, Kcp1),
                                        Kcp12 = Kcp11#kcp{probe_wait = Kcp11#kcp.probe_wait + Kcp11#kcp.probe_wait div 2}, %% 探查时间扩充一半
                                        Kcp13 = ?IF(Kcp12#kcp.probe_wait > ?IKCP_PROBE_LIMIT, Kcp12#kcp{probe_wait = ?IKCP_PROBE_LIMIT}, Kcp12), %% 如果新的扩充时间大于120s
                                        Kcp13#kcp{ts_probe = Current + Kcp13#kcp.probe_wait, probe = Kcp13#kcp.probe bor ?IKCP_ASK_SEND}; %% 更新下一次探查时间，设置此次为需要探查
                                    _ ->
                                        Kcp1
                                end
                        end;
                    _ ->
                        Kcp1#kcp{ts_probe = 0, probe_wait = 0} %% 如果知道远程端口尺寸，则无需设定探查时间与下次探查时间
                end,

            %% flush window probing commands
            %% 请求或者告知窗口大小
            {Seg1, Ptr2} =
                case Kcp2#kcp.probe band ?IKCP_ASK_SEND =/= 0 of            %% 如果需要探查，设定命令字
                    true ->
                        Ptr11 = make_space(?IKCP_OVERHEAD, Ptr1, Mtu),
                        {Seg0#segment{cmd = ?IKCP_CMD_WASK}, encode(Seg0, Ptr11)};
                    _ ->
                        {Seg0, Ptr1}
                end,
            {Seg2, Ptr3} =
                case Kcp2#kcp.probe band ?IKCP_ASK_TELL =/= 0 of
                    true ->
                        Ptr21 = make_space(?IKCP_OVERHEAD, Ptr2, Mtu),
                        {Seg1#segment{cmd = ?IKCP_CMD_WINS}, encode(Seg1, Ptr21)};
                    _ ->
                        {Seg1, Ptr2}
                end,
            Kcp3 = Kcp2#kcp{probe = 0},

            %% calculate window size
            Cwnd = min(Kcp3#kcp.snd_wnd, Kcp3#kcp.rmt_wnd), %% 传输窗口是发送端与接收端中较小的一个
            Cwnd1 = ?IF(Kcp3#kcp.nocwnd == 0, min(Kcp3#kcp.cwnd, Cwnd)), %% 如果未取消拥塞控制,正在发送的数据大小与窗口尺寸比较

            %% sliding window, controlled by snd_nxt && sna_una+cwnd
            {Kcp4, NewSegsCount, ReserveSndQueue} = sliding_window(lists:reverse(Kcp3#kcp.snd_queue), Kcp3, 0, Cwnd1),

            %%  如果有将snd_queue中的数据移动至snd_buf中，则需要将snd_queue中的对应数据删除
            Kcp5 = Kcp4#kcp{snd_queue = lists:reverse(ReserveSndQueue)},

            %% 设置重传策略
            %% calculate resent
            Resent = ?IF(Kcp5#kcp.fastresend =< 0, 4294967295, Kcp5#kcp.fastresend), %% 如果触发快速重传的重复ack个数 <= 0, 4294967295 = 0xffffffff
            Current = ?CURRENT,
            MinRto = Kcp5#kcp.interval,
            %% Change:新变更传输状态的数量，LostSegs:丢失片段数
            {Ptr4, Kcp6, MinRto1, Change, LostSegs} = bounds_check_elimination(Kcp5#kcp.snd_buf, Ptr3, Kcp5, Current, Resent, NewSegsCount, Seg, MinRto, 0, 0),

            %% flash remain segments
            flush_buffer(Ptr4),

            %% cwnd update
            Kcp7 =
                case Kcp6#kcp.nocwnd == 0 of
                    %%  update ssthresh
                    %%	rate halving, https://tools.ietf.org/html/rfc6937
                    true ->
                        Kcp61 =
                            case Change > 0 of
                                true ->
                                    Inflight = Kcp6#kcp.snd_nxt - Kcp6#kcp.snd_una,     %% 待发送的与未确认最小值得差值==未确认的总数
                                    NewSsThresh = ?IF(Inflight div 2 < ?IKCP_THRESH_MIN, ?IKCP_THRESH_MIN, Inflight div 2),
                                    Kcp6#kcp{
                                        ssthresh =  NewSsThresh %% 如果 拥塞窗口阈值 小于 拥塞窗口最小值
                                        ,cwnd = NewSsThresh + Resent              %% 拥塞窗口阈值+重传数量
                                        ,incr = Kcp6#kcp.cwnd * Kcp6#kcp.mss            %% 可发送的最大数据量=拥塞窗口*最大分片大小
                                    };
                                _ ->
                                    Kcp6
                            end,
                        %% congestion control, https://tools.ietf.org/html/rfc5681
                        Kcp62 =
                            case LostSegs > 0 of
                                true ->
                                    Kcp61#kcp{
                                        ssthresh = ?IF(Cwnd div 2 < ?IKCP_THRESH_MIN, ?IKCP_THRESH_MIN, Cwnd1 div 2)
                                        ,cwnd = 1
                                        ,incr = Kcp61#kcp.mss
                                    };
                                _ ->
                                    Kcp61
                            end,
                        case Kcp62#kcp.cwnd < 1 of
                            true ->
                                Kcp61#kcp{
                                    cwnd = 1
                                    ,incr = Kcp62#kcp.mss
                                };
                            _ ->
                                Kcp62
                        end;
                    _ ->
                        Kcp6
                end,
            {Kcp7, MinRto1}
    end.

%% 发送残留的数据
flush_buffer(<<>>) ->
    ok;
flush_buffer(Ptr) ->
    out_put(Ptr).

%% 将确定要检查的内容进行遍历
bounds_check_elimination([], Ptr, Kcp, _Current, _Resent, _NewSegsCount, _ThisSeg, MinRto, Change, LostSegs) ->
    {Ptr, Kcp, MinRto, Change, LostSegs};
bounds_check_elimination([#segment{xmit = Xmit, fastack = FastAck, resendts = Resendts} = Seg | Ref], Ptr, Kcp, Current, Resent, NewSegsCount, ThisSeg, MinRto, Change, LostSegs) ->
    case Seg#segment.acked == 1 of  %% 如果此记录以及被确认过
        true ->
            bounds_check_elimination(Ref, Ptr, Kcp, Current, Resent, NewSegsCount, ThisSeg, MinRto, Change, LostSegs);
        _ ->
            {Needsend, Seg1, Change1, LostSegs1} =
                if
                    Xmit == 0 -> {true, Seg#segment{    %% initial transmit 如果传输状态为0--> 未发送
                        rto = Kcp#kcp.rx_rto,           %% 重传超时时间
                        resendts = Current + Seg#segment.rto    %% 发送时间
                    }, Change, LostSegs};
                    FastAck >= Resent -> {true, Seg#segment{ %% fast retransmit 快速确认ack数>快速重传数
                        fastack = 0,
                        rto = Kcp#kcp.rx_rto,
                        resendts = Current + Seg#segment.rto
                    }, Change + 1, LostSegs};
                    FastAck > 0 andalso NewSegsCount =:= 0 -> {true, Seg#segment{ %% early retransmit 快速确认数>0且没有新数据加入
                        fastack = 0,
                        rto = Kcp#kcp.rx_rto,
                        resendts = Current + Seg#segment.rto
                    }, Change + 1, LostSegs};
                    Current - Resendts >= 0 -> {true, Seg#segment{  %% RTO  当前时间已经达到重传时间的
                        fastack = 0,
                        rto = ?IF(Kcp#kcp.nodelay == 0, Kcp#kcp.rx_rto, Kcp#kcp.rx_rto div 2), %% 如果不启动无延迟模式(延迟)；当前Segment的每一次重传时间加rx_rto
                        resendts = Current + Seg#segment.rto
                    }, Change, LostSegs + 1};
                    true -> {false, Seg, Change, LostSegs}
                end,
            {Kcp1, Ptr1, Seg2} =
                case Needsend of
                    true ->
                        Seg12 = Seg1#segment{xmit = Seg1#segment.xmit + 1, ts = Current, wnd = ThisSeg#segment.wnd, una = ThisSeg#segment.una},
                        Need = ?IKCP_OVERHEAD + erlang:byte_size(Seg12#segment.data),
                        Ptr11 = make_space(Need, Ptr, Kcp#kcp.mtu),
                        Ptr12 = encode(Seg12, Ptr11),
                        Ptr13 = <<Ptr12/bytes, (Seg12#segment.data)/bytes>>,
                        Kcp11 =
                            case Seg12#segment.xmit >= Kcp#kcp.dead_link of
                                true->
                                    %% 连接状态（-1 表示断开连接）
                                    Kcp#kcp{state = -1};
                                _ ->
                                    Kcp
                            end,
                        {Kcp11, Ptr13, Seg12};
                    _ ->
                        {Kcp, Ptr, Seg1}
                end,
            Rto = Seg2#segment.resendts - Current,
            MinRto1 =
                case Rto > 0 andalso Rto < MinRto of
                    true -> Rto;
                    _ -> MinRto
                end,
            bounds_check_elimination(Ref, Ptr1, Kcp1, Current, Resent, NewSegsCount, ThisSeg, MinRto1, Change1, LostSegs1)
    end.

%% kcp.snd_nxt[待发送的sn]-(kcp.snd_una[已经确认的连续sn号]+cwnd[发送途中的数量])>=0
%% 表示发送中+未确认的已经大于cwnd的尺寸了，需要等待
sliding_window([], Kcp, NewSegsCount, _Cwnd) ->
    {Kcp, NewSegsCount, []};
sliding_window([NewSeg | SndQueue], Kcp, NewSegsCount, Cwnd) ->
    case Kcp#kcp.snd_nxt - Kcp#kcp.snd_una - Cwnd >= 0 of
        true->
            {Kcp, NewSegsCount, [NewSeg | SndQueue]};
        _ ->
            sliding_window(SndQueue,
                Kcp#kcp{
                snd_buf = Kcp#kcp.snd_buf ++ [NewSeg#segment{ %% 从开始位置取数据,将数据移动到snd_buf中去
                    conv = Kcp#kcp.conv, %% 客户端号，一个客户端的号码在同一次启动中是唯一的
                    cmd = ?IKCP_CMD_PUSH, %% 数据推出命令字
                    sn = Kcp#kcp.snd_nxt %% 设定
                    }],
                snd_nxt = Kcp#kcp.snd_nxt + 1
            }, NewSegsCount + 1, Cwnd)
    end.

%% acklist中数据发送
flush_acknowledges([], _Kcp, Seg, Ptr) ->
    {Seg, Ptr};
flush_acknowledges([Ack | AckList], Kcp, Seg, Ptr) ->
    Ptr1 = make_space(?IKCP_OVERHEAD, Ptr, Kcp#kcp.mtu),
    case Ack#segment.sn >= Kcp#kcp.rcv_nxt orelse AckList == [] of
        true ->
            flush_acknowledges(AckList, Kcp, Seg#segment{sn = Ack#segment.sn, ts = Ack#segment.ts}, encode(Seg, Ptr));
        _ ->
            flush_acknowledges(AckList, Kcp, Seg, Ptr1)
    end.

%% 删除Ptr中一个Seg
encode(Seg, Ptr) ->
    <<Ptr/bytes,
        (Seg#segment.conv):32/little-integer
        ,(Seg#segment.cmd):8/little-integer
        ,(Seg#segment.frg):8/little-integer
        ,(Seg#segment.wnd):16/little-integer
        ,(Seg#segment.ts):32/little-integer
        ,(Seg#segment.sn):32/little-integer
        ,(Seg#segment.una):32/little-integer
        ,(erlang:length(Seg#segment.data)):32/little-integer
    >>.

decode(Data) ->
    <<
        Conv:32/little-integer
        ,Cmd:8/little-integer
        ,Frg:8/little-integer
        ,Wnd:16/little-integer
        ,Ts:32/little-integer
        ,Sn:32/little-integer
        ,Una:32/little-integer
        ,Len:32/little-integer
        ,Other/bytes
    >> = Data,
    {Conv, Cmd, Frg, Wnd, Ts, Sn, Una, Len, Other}.

%% makeSpace makes room for writing
make_space(Space, Ptr, Mtu) ->
    Size = erlang:byte_size(Ptr),
    %% 小数据打包,达到mtu大小再发送
    case Size + Space > Mtu of
        true ->
            out_put(Ptr),
            <<>>;
        _ ->
            Ptr
    end.

wnd_unused(Kcp) ->
    case length(Kcp#kcp.rcv_queue) < Kcp#kcp.rcv_wnd of
        true ->
            Kcp#kcp.rcv_wnd -  Kcp#kcp.rcv_queue;
        _ ->
            0
    end.

out_put(Buffer) ->
    111.
%%======================================================================================================================


%%======================================================================================================================
%% Input
%%======================================================================================================================
%%// Input a packet into kcp state machine.
%%//
%%// 'regular' indicates it's a real data packet from remote, and it means it's not generated from ReedSolomon
%%// codecs.
%%//
%%// 'ackNoDelay' will trigger immediate ACK, but surely it will not be efficient in bandwidth
%%/**
%% * 6.1 数据发送给接受端，接受端通过input进行接受，并解包receive buf，有确认的数据包recv_buf-->recv_queue
%% * 1. 解包
%% * 2. 确认是否有新的确认块，确认块需要重recv_buf-->recv_queue
%% * 3. 更新相关参数，主要是是否有确认过未删除，recv_buf，recv_queue的尺寸
%% */
input(Kcp, Data, Regular, AckNoDelay) ->
    SndUna = Kcp#kcp.snd_una,
    case erlang:byte_size(Data) < ?IKCP_OVERHEAD of
        true ->
            {Kcp, -1};
        _ ->
            {Kcp1, Flag, Latest, WindowSlides} = loop_decode(Data, Kcp, Regular, false, 0, 0, 0),
            Kcp2 =
                case Flag =/= 0 andalso Regular of
                    true ->
                        Current = ?CURRENT,
                        case Current - Latest >= 0 of
                            true ->
                                kcp_utils:update_ack(Kcp1, Current - Latest);
                            _ ->
                                Kcp1
                        end;
                    _ ->
                        Kcp1
                end,

            %% 拥塞控制
            Kcp3 =
                case Kcp2#kcp.nocwnd == 0 of
                    true->
                        case Kcp2#kcp.snd_una - SndUna > 0 of
                            true ->
                                case Kcp2#kcp.cwnd < Kcp2#kcp.rmt_wnd of
                                    true->
                                        Mss = Kcp2#kcp.mss,
                                        Kcp21 =
                                            case Kcp2#kcp.cwnd < Kcp2#kcp.ssthresh of
                                                true ->
                                                    Kcp2#kcp{
                                                        cwnd = Kcp2#kcp.cwnd + 1,
                                                        incr = Kcp2#kcp.incr + Mss
                                                    };
                                                _ ->
                                                    Kcp21 = ?IF(Kcp2#kcp.incr < Mss, Kcp2#kcp{incr = Mss}, Kcp2),
                                                    Kcp22 = Kcp21#kcp{incr = Kcp21#kcp.incr + (Mss*Mss)/Kcp21#kcp.incr + (Mss / 16)},
                                                    case (Kcp22#kcp.cwnd+1)*Mss =< Kcp22#kcp.incr of
                                                        true ->
                                                            case Mss > 0 of
                                                                true ->
                                                                    Kcp22#kcp{cwnd = (Kcp22#kcp.incr + Mss - 1) / Mss};
                                                                _ ->
                                                                    Kcp22#kcp{cwnd = Kcp22#kcp.incr + Mss - 1}
                                                            end;
                                                        _ -> Kcp22
                                                    end
                                            end,
                                        ?IF(Kcp21#kcp.cwnd > Kcp21#kcp.rmt_wnd, Kcp21#kcp{cwnd = Kcp21#kcp.rmt_wnd}, Kcp21#kcp{incr =  Kcp21#kcp.rmt_wnd * Mss});
                                    _ -> Kcp2
                                end;
                            _ -> Kcp2
                        end;
                    _ -> Kcp2
                end,
            if
                %% 有新的确认数据
                WindowSlides ->
                    flush(Kcp3, false);
                AckNoDelay andalso length(Kcp3#kcp.acklist) > 0 ->
                    flush(Kcp3, true);
                true ->
                    {Kcp3, 0}
            end
    end.

loop_decode(Data, Kcp, Regular, WindowSlides, InSegs, Flag, Latest) ->
    {Conv, Cmd, Frg, Wnd, Ts, Sn, Una, Len, Data1} = decode(Data),
    case Conv =/= Kcp#kcp.conv of %%判断连续号，确认数据是否应该是目标来源的
        %% return -1
        true -> {Flag, Ts, Kcp, WindowSlides};
        _ ->
            case erlang:byte_size(Data1) < Len of %% 剩余data长度是否小于元数据中指定的数据长度
                %% return -2
                true -> {Flag, Ts, Kcp, WindowSlides};
                _ ->
                    {Flag1, Latest1, Kcp4} =
                        case lists:member(Cmd, [?IKCP_CMD_PUSH, ?IKCP_CMD_ACK, ?IKCP_CMD_WASK, ?IKCP_CMD_WINS]) of
                            true ->
                                %% only trust window updates from regular packets. i.e: latest update
                                Kcp1 = ?IF(Regular, Kcp#kcp{rmt_wnd = Wnd}, Kcp),
                                {NewSndBuf , Count} = kcp_utils:parse_una(Kcp1#kcp.snd_buf, Una, 0),
                                Kcp2 = Kcp1#kcp{snd_buf = NewSndBuf},
                                WindowSlides1 = ?IF(Count > 0, true, WindowSlides),   %% 如果有新的确认数据
                                Kcp3 = kcp_utils:shrink_buf(Kcp2),
                                case Cmd of
                                    ?IKCP_CMD_ACK ->  %% 窗口应答数据
                                        Kcp31 = kcp_utils:parse_ack(Kcp3, Sn),  %% 确认snd_buf中的数据是否存在已经确认，但是未删除的seg，删除掉，空出空间
                                        Kcp32 = kcp_utils:parse_fast_ack(Kcp31, Sn, Ts), %% 更新快速确认数，判断snd_buf中，是否存在，sn小，ts也比较早的数据，进行快速确认，以便空出空间
                                        {Flag bxor 1, Ts, Kcp32, WindowSlides1};
                                    ?IKCP_CMD_PUSH ->   %% 用户数据
                                        case Sn - Kcp#kcp.rcv_nxt + Kcp#kcp.rcv_wnd < 0 of
                                            true ->
                                                Kcp1 = kcp_utils:ack_push(Kcp, Sn, Ts), %% 更新acklist表
                                                case Sn - Kcp#kcp.rcv_nxt of
                                                    true ->
                                                        Seg = #segment{
                                                            conv = Conv
                                                            ,cmd = Cmd
                                                            ,frg = Frg
                                                            ,wnd = Wnd
                                                            ,ts = Ts
                                                            ,sn = Sn
                                                            ,una = Una
                                                            ,data = lists:sublist(Data, Len) %% delayed data copying
                                                        },
                                                        {Kcp31, _} = parse_data(Kcp, Seg),
                                                        {Flag, Latest, Kcp31, WindowSlides1};
                                                    _ ->
                                                        {Flag, Latest, Kcp3, WindowSlides1}
                                                end;
                                            _ ->
                                                {Flag, Latest, Kcp3, WindowSlides1}
                                        end;
                                    ?IKCP_CMD_WASK ->
                                        {Flag, Latest, Kcp3#kcp{probe = Kcp3#kcp.probe bxor ?IKCP_ASK_TELL},WindowSlides1};
                                    ?IKCP_CMD_WINS ->
                                        {Flag, Latest, Kcp3, WindowSlides1};
                                    %% return -3
                                    _ -> {Flag, Latest, Kcp3, WindowSlides1}
                                end,
                                <<_:Len, Data3/bytes>> = Data1,
                                loop_decode(Data3, Kcp4, Regular, WindowSlides1, InSegs + 1, Flag1, Latest1);
                            _ ->
                                %% 数据命令字错误
                                %% return -3
                                {Flag, Latest, Kcp, WindowSlides}
                        end
            end
    end.

parse_data(Kcp, Seg) ->
    Sn = Seg#segment.sn,
    case Sn - Kcp#kcp.rcv_nxt - Kcp#kcp.rcv_wnd >= 0 orelse Sn - Kcp#kcp.rcv_nxt < 0 of
        true ->
            true;
        _ ->
            N = erlang:length(Kcp#kcp.rcv_buf) - 1,
            InsertIdx = 0,
            Repeat = false,
            {Repeat1, InsertIdx1} = loop_parse_data_1(N, Kcp#kcp.rcv_buf, Sn, Repeat, InsertIdx),
            Kcp1 =
                case not Repeat1 of
                    true ->
                        case InsertIdx1 == N + 1 of
                            true ->
                                Kcp#kcp{rcv_buf = Kcp#kcp.rcv_buf ++ [Seg]};
                            _ ->
                                {Head, Tail} = lists:split(InsertIdx1, Kcp#kcp.rcv_buf),
                                Kcp#kcp{rcv_buf = Head ++ [Seg] ++ Tail}
                        end;
                    _ ->
                        Kcp
                end,
            {NewRcvBuf, Kcp2, _Count, AddRcvQueue} = loop_parse_data_2(Kcp1#kcp.rcv_buf, 0, Kcp1, Kcp1#kcp.rcv_queue, []),
            {Kcp2#kcp{rcv_buf = NewRcvBuf, rcv_queue = Kcp2#kcp.rcv_queue ++ lists:reverse(AddRcvQueue)}, Repeat1}
    end.

loop_parse_data_2([], Count, Kcp, _RcvQueueLen, Res) ->
    {[], Kcp, Count, Res};
loop_parse_data_2([Seg | RcvBuf], Count, Kcp, RcvQueueLen, Res) ->
    case Seg#segment.sn == Kcp#kcp.rcv_nxt andalso RcvQueueLen + Count < Kcp#kcp.rcv_wnd of
        true ->
            loop_parse_data_2(RcvBuf, Count + 1, Kcp#kcp{rcv_nxt = Kcp#kcp.rcv_nxt + 1}, RcvQueueLen, [Seg | Res]) ;
        _ ->
            {[Seg | RcvBuf], Kcp, Count, Res}
    end.

loop_parse_data_1(I, [], Sn, Repeat, InsertIdx) ->
    {Repeat, InsertIdx};
loop_parse_data_1(I, [Seg | RcvBuf], Sn, Repeat, InsertIdx) ->
    case Seg#segment.sn == Sn of
        true ->{true, InsertIdx};
        _ ->
            case Sn - Seg#segment.sn > 0 of
                true ->
                    {Repeat, I + 1};
                _ ->
                    loop_parse_data_1(I - 1, RcvBuf, Sn, Repeat, InsertIdx)
            end
    end.


%%======================================================================================================================



%%======================================================================================================================
%% Recv
%%======================================================================================================================
%%/**
%% * 6.2 获取完整用户数据：从receive queue中进行拼装完整用户数据
%% * 1. 遍历rcv_queue中，是否可以获取到连续块却最后一块的frg=0的情况，如果存在，则提取一个完整用户数据；并删除rcv_queue中对应的数据块，释放空间
%% * 2. 提取完成后，遍历rcv_buf中，是否还有有效数据，更新到rcv_queue中；等待下次进行判断
%% */
recv(Buffer, Kcp) ->
    PeekSize = peek_size(Kcp),
    case PeekSize < 0 of
        true -> throw(-1)
    end,
    case PeekSize > length(Buffer) of
        true -> throw(-2)
    end,
    FastRecover = length(Kcp#kcp.rcv_queue) >= length(Kcp#kcp.rcv_wnd),
    {Res, N, Count} = merge_fragment(Kcp#kcp.rcv_queue, Kcp, <<>>, 0, 0),
    Kcp1 =
        case Count > 0 of
            true ->
                RcvQueue = Kcp#kcp.rcv_queue,
                LenRcvQueue = length(RcvQueue),
                Kcp#kcp{snd_queue = lists:sublist(RcvQueue, Count + 1, LenRcvQueue - Count)};
            _ -> Kcp
        end,
    {Count1, Kcp2} = loop_rcv_buf(Kcp1#kcp.rcv_buf, 0, Kcp1),
    Kcp3 =
        case Count1 > 0 of
            true->
                RcvQueue2 = Kcp2#kcp.rcv_queue,
                RcvBuf2 = Kcp2#kcp.rcv_buf,
                LenRcvBuf2 = length(RcvBuf2),
                Kcp2#kcp{rcv_queue = RcvQueue2 ++ RcvBuf2, rcv_buf = lists:sublist(RcvBuf2, Count + 1, LenRcvBuf2 - Count)};
            _ ->
                Kcp2
        end,
    Kcp4 =
        case length(Kcp3#kcp.rcv_queue) < Kcp3#kcp.rcv_wnd andalso FastRecover of
            true ->
                Probe = Kcp3#kcp.probe,
                Kcp3#kcp{probe = Probe bor ?IKCP_ASK_TELL};
            _ ->
                Kcp3
        end,
    {Res, N, Kcp4}.

loop_rcv_buf(_RcvBuf, Count, Kcp) ->
    {Count, Kcp};
loop_rcv_buf([#segment{sn = Sn, frg = Frg} | RcvBuf], Count, #kcp{rcv_nxt = RcvNxt, rcv_queue = RcvQueue, rcv_wnd = RcvWnd} = Kcp) ->
    case Sn == RcvNxt andalso length(RcvQueue) + Count < RcvWnd of
        true ->
            loop_rcv_buf(RcvBuf, Count + 1, Kcp#kcp{rcv_nxt = RcvNxt + 1}) ;
        _ ->
            {Count, Kcp}
    end.


%% checks the size of next message in the recv queue
peek_size(#kcp{rcv_queue = RcvQueue}) ->
    case length(RcvQueue) of
        0 -> -1;
        _ ->
            [#segment{data = Data, frg = Frg}| _] = RcvQueue,
            case Frg of
                0 ->
                    length(Data);
                _ ->
                    case length(RcvQueue) < Frg + 1 of
                        true -> -1;
                        _ ->
                            loop_rcv_queue(RcvQueue, 0)
                    end
            end
    end.

merge_fragment(_, _, Res, N, Count) ->
    {Res, N, Count};
merge_fragment([#segment{data = SegData, frg = SegFrg} = Seg | RcvQueue], Kcp, Res, N, Count) ->
    Res1 = <<Res/bytes, SegData/bytes>>,
    N1 = N + erlang:byte_size(SegData),
    case SegFrg of
        0 ->
            {Res1, N1, Count + 1};
        _ ->
            merge_fragment(RcvQueue, Kcp, Res1, N1, Count + 1)
    end.

loop_rcv_queue([], Len) ->
    Len;
loop_rcv_queue([#segment{data = Data, frg = Frg} | RcvQueue], Len) ->
    NewLen = Len + length(Data),
    case Frg == 0 of
        true ->
            NewLen;
        _ ->
            loop_rcv_queue(RcvQueue, NewLen)
    end.
%%======================================================================================================================