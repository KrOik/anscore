# 主机加载与原始结果回读

UART：115200，8N1。50MHz下每位434周期。所有多字节整数小端；CRC8多项式07、初值0、不反射、不异或输出。

请求18字节：AA55同步、cmd1、address2、payload12、CRC1。CRC覆盖cmd到payload，不覆盖同步。响应31字节：55AA同步、cmd1、status1、address2、raw24、CRC1，CRC覆盖cmd到raw。每次完整请求等待完整响应再发送下一次。status0成功、1CRC错误、2忙/边界错误、3未知命令。

|cmd|操作|字段|
|---:|---|---|
|0|身份|raw低8位16，接着profile8、50MHz16、magic32=53595032|
|1|加载|address0～255，payload96刺激；仅空闲允许|
|2|运行|address输入条数；payload[5:0]选择；bit8输出背压；[31:16]响应数|
|3|状态|raw bit0错误、1完成、2忙；[31:16]issued，[47:32]captured，[79:48]cycles，[111:80]协议错误数|
|4|读取|address捕获行，raw192原始输出；仅空闲允许|
|5|测量|address0：六个32位字inputs、outputs、input_stalls、output_stalls、latency_min、latency_max；address1：cycles、max_output_gap、errors|

长度1～256，否则运行显式done/error。运行前复位选择的DUT，保留加载RAM。默认1000000时钟超时（20ms）；超时后done/error，保留已捕获行。背压模式每8周期阻塞2周期。同步读RAM需要控制器等待边缘后才发送数据。

profile0中刺激a=payload[31:0]、b=[63:32]、c=[95:64]：

|选择|刺激|原始输出低位布局|
|---:|---|---|
|0 switch|a数据；b[1:0]源、[3:2]目的、4末拍；c[3:0]keep、[15:8]user|data32、keep4、user8、dest2、last1|
|1 width down|a数据；b[3:0]keep、4末拍；c[7:0]user|data32、keep4、user8、last1|
|2 packet|a数据，b0末拍|data32、last1、dropped32|
|3 isolation|完整96位|原96位|
|4 AXI|a地址低16、bit16写、[19:17]PROT、20W先；b数据；c[3:0]strobes|value32、resp2、write1、空13、地址16|
|5 timeout|a0注重叠；b低16截止；c低16响应延迟|timeouts32、overlaps32、late32、max_age16|
|6 config|a数据；b低2索引、[7:4]strobes；c低16应用延迟|active128、version32|
|7 snapshot|完整96位live，高32位0|snapshot128、timestamp64|
|8 timestamp|a数据，b低16tag；c31load、c低31load_time|data32、tag16、time64|
|9 alignment|a数据，bepoch，c低2通道|frame128、epoch32、missing4|
|10 trigger|a数据，b0触发；每RUN自动arm|data32、last1、length16|
|11 calibration|a低24样本；b低16gain、高16tag；c低24offset、[25:24]通道|sample24、channel2、sat1、空5、tag32|
|12 March|a0比较注错、a1总线错误、a2停止请求ready|errors32、cycles32、first_addr6、first_phase3|
|13 fault|a数据，bmask；c低2mode、2enable、[23:8]period|data32、injected1、error1、空30、injections32|
|14 metrics|96位身份流，transport内实际监控器|身份96位；cmd5读取真正计量|
|15 replay|96位身份流，transport内实际加载/捕获RAM|身份96位；cmd3读取真正回放计量|

profile1～7：a/b/c直接送原核，CE=1；raw低32位result、接着aux32、fault1。所有未使用高位0。profile0的packet夹具两域同源同频，独立时钟比在原生仿真测试。AXI夹具每窗口有1个字节可写寄存器；局部地址bit11产生SLVERR，其他映射地址OKAY，高地址DECERR。

profile8仅选择0：a为24位数字样本，b为epoch0～16，c低2为通道。先拼四通道帧再串行校准：各通道Q2.14增益8192、16384、-8192、32767，偏置100、-100、0、500；时间戳在校准后样本接受时采集。tag=epoch*4+channel；tag63触发，读回59～67的9条记录。raw低32为sample24/channel2/saturation1/空5，接着tag16、采样时间64，bit112末拍，[143:128]长度。68条刺激支持每epoch不同通道到达顺序。

测量边界：延迟监控仅适用于顺序1:1、未完成≤16的流。宽度拆分、整包丢弃、四路聚合、触发子窗口和profile8不满足此前提，errors会明确记录队列不匹配/溢出；这些运行仅使用输入/输出总数和replay总周期，不能使用其延迟数当性能结论。真实时间戳不与软件伪造的固定周期值比较，而检查元数据、单调性并保存全部64位。

当前链接是单主机请求/应答，无序号、重传或部分帧超时协议。CRC错误有回应；物理串口帧错误使接收器重新同步。未知命令/选择不触发运行。通信失步时主机报错并保存证据，不自动修改刺激或期待值。

JTAG自动回放的单向输出仍为31字节响应格式。cmd83：状态，address高8位case_id、低8位0。cmd84：原始捕获行，address高8位case_id、低8位行号。cmd85：测量，低8位0/1选择计数页。cmd86：终止帧，address=profile，raw低32为4155544F、[39:32]案例数。case_id=core*2+seed-1，偶数无背压，奇数有背压。状态中[111:80]在此模式记录真实接收引脚跳变数，不是命令解析错误数。

自动回放开始有0.5秒延迟供主机打开串口。每个case先从JTAG初始化ROM同步加载刺激到replay RAM；加载时间不计入回放cycles。ROM只含主机刺激；对应MEM文件SHA256绑定到build报告，期待值只在独立Python模型中生成。记录逐行连续、每帧CRC、案例完成、接受/捕获计数及终止帧均需通过才能判定物理测试PASS。
