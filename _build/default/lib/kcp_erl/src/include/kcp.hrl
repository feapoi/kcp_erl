%%%-------------------------------------------------------------------
%%% @author 100621
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. 7月 2021 16:08
%%%-------------------------------------------------------------------
-author("100621").
-define(IF(_CONDITION, _DO), ?IF(_CONDITION, _DO, ok)).
-define(IF(_CONDITION, _DO, _ELSE), case _CONDITION of true -> _DO; else -> _ELSE end).

-define(CURRENT, erlang:system_time(millisecond) - persistent_term:get(current)).

-define(IKCP_RTO_NDL, 30).
-define(IKCP_RTO_MIN, 100).
-define(IKCP_RTO_DEF, 200).
-define(IKCP_RTO_MAX, 60000).
-define(IKCP_CMD_PUSH, 81).
-define(IKCP_CMD_ACK, 82).
-define(IKCP_CMD_WASK, 83).
-define(IKCP_CMD_WINS, 84).
-define(IKCP_ASK_SEND, 1).
-define(IKCP_ASK_TELL, 2).
-define(IKCP_WND_SND, 32).
-define(IKCP_WND_RCV, 32).
-define(IKCP_MTU_DEF, 1400).
-define(IKCP_ACK_FAST, 3).
-define(IKCP_INTERVAL, 100).
-define(IKCP_OVERHEAD, 24).
-define(IKCP_DEADLINK, 20).
-define(IKCP_THRESH_INIT, 2).
-define(IKCP_THRESH_MIN, 2).
-define(IKCP_PROBE_INIT, 7000).
-define(IKCP_PROBE_LIMIT, 120000).
-define(IKCP_SN_OFFSET, 12).


-record(kcp, {
    %% conv:客户端来源id； mtu：最大传输单元(默认1400)；mss: 最大片段尺寸MTU-OVERHEAD；state: 连接状态（0xFFFFFFFF表示断开连接）
    conv = 0,mtu = ?IKCP_MTU_DEF,mss = ?IKCP_MTU_DEF - ?IKCP_OVERHEAD,state = 0
    %% snd_una: 第一个未确认的包; snd_nxt：下一个要发送的sn; rcv_nxt：下一个应该接受的sn
    ,snd_una = 0,snd_nxt = 0,rcv_nxt = 0
    %% 拥塞窗口阈值
    ,ssthresh = ?IKCP_THRESH_INIT
    %% RTT的平均偏差; RTT的一个加权RTT平均值，平滑值; RTT: 一个报文段发送出去，到收到对应确认包的时间差。
    ,rx_rttvar = 0,rx_srtt = 0
    %% 由ack接收延迟计算出来的重传超时时间(重传超时时间)，最小重传超时时间
    ,rx_rto = ?IKCP_RTO_DEF,rx_minrto = ?IKCP_RTO_MIN
    %% 发送窗口；接收窗口；远程窗口(发送端获取的接受端尺寸)；拥塞窗口大小(传输窗口)；探查变量
    ,snd_wnd = ?IKCP_WND_SND,rcv_wnd = ?IKCP_WND_RCV,rmt_wnd = ?IKCP_WND_RCV,cwnd = 0,probe = 0
    %% 内部flush刷新间隔;  下次flush刷新时间戳
    ,interval = ?IKCP_INTERVAL,ts_flush = ?IKCP_INTERVAL
    %% 是否启动无延迟模式：0不需要，1需要；updated: 是否调用过update函数的标识
    ,nodelay = 0,updated = 0
    %% 窗口探查时间，窗口探查时间间隔
    ,ts_probe = 0,probe_wait = 0
    %% 最大重传次数; 可发送的最大数据量
    ,dead_link = ?IKCP_DEADLINK,incr = 0
    %% 重传
    ,fastresend = 0
    %% 取消拥塞控制，是否是流模式
    ,nocwnd = 0, stream = 0
    %% 发送队列; 发送buf; 接收队列; 接收buf
    ,snd_queue = [], rcv_queue = [], snd_buf = [], rcv_buf = []
    %% 待发送的ack列表(包含sn与ts)  |sn0|ts0|sn1|ts1|... 形式存在
    ,acklist = []
    %% 存储消息字节流的内存
    ,buffer = <<>>
    %% 不同协议保留位数
    ,reserved = 0
    %% 回调函数
    ,output
}).

-record(segment, {
    conv = 0
    ,cmd = 0
    ,frg = 0    %% 分片
    ,wnd = 0    %% 接收窗口大小
    ,ts = 0     %% 时间序列
    ,sn = 0     %% 序列号
    ,una = 0    %% 下一个可接收的序列号，其实就是确认号
    ,rto = 0    %% 由ack接收延迟计算出来的重传超时时间
    ,xmit = 0   %% 发送分片的次数，每发送一次加一
    ,resendts = 0   %% 下次超时重传的时间戳
    ,fastack = 0    %% 收到ack时计算的该分片被跳过的累计次数
    ,acked = 0      %% mark if the seg has acked
    ,data = <<>>
}).

-record(ack_item, {
    sn = 0
    ,ts = 0
}).