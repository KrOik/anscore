# 新增16个系统IP

|序号|核|类别|功能|
|---:|---|---|---|
|0|[frame_switch4](../ip/frame_switch4/SPEC.md)|stream|四入四出帧锁定轮询；帧结束后释放，空闲选择需要1周期。|
|1|[width_converter](../ip/width_converter/SPEC.md)|stream|MODE0压缩TKEEP有效字节32→8；MODE1按4字节或TLAST聚合8→32。|
|2|[packet_async_fifo](../ip/packet_async_fifo/SPEC.md)|stream|同步双时钟RAM整包存储，TLAST后提交长度/请求翻转，末拍消费后确认。|
|3|[backpressure_isolator](../ip/backpressure_isolator/SPEC.md)|stream|两拍存储，s_ready仅取决于寄存器占用；占用1时持续II1。|
|4|[axi_lite_interconnect](../ip/axi_lite_interconnect/SPEC.md)|control|16位地址，4个4K窗口；独立AW/W收集与读通道；未映射返回DECERR。|
|5|[bus_timeout_monitor](../ip/bus_timeout_monitor/SPEC.md)|control|握手后计龄；响应在截止边缘优先；超时保持在途等待真实响应。|
|6|[atomic_config](../ip/atomic_config/SPEC.md)|control|按字节写影子寄存器；commit包含同边缘写；apply_safe后整组更新。|
|7|[register_snapshot](../ip/register_snapshot/SPEC.md)|control|就绪时一次采样整组live、64位周期和递增snapshot_id。|
|8|[timestamp64](../ip/timestamp64/SPEC.md)|acquisition|记录输入接受边缘之前的64位计数；load优先改变随后计数。|
|9|[frame_align4](../ip/frame_align4/SPEC.md)|acquisition|四路按epoch拼帧；旧epoch消费丢弃并计数，未来epoch保持；缺失超时补零。|
|10|[trigger_window](../ip/trigger_window/SPEC.md)|acquisition|同步环形RAM；触发拍前最多PRE拍，后POST拍；冻结后读出且保持停顿数据。|
|11|[calibration24](../ip/calibration24/SPEC.md)|acquisition|有符号24位样本×16位Q2.14增益，向负无穷取整，再加24位偏置，24位饱和。|
|12|[march_controller](../ip/march_controller/SPEC.md)|test|完整March C-：↑w0，↑r0w1，↑r1w0，↓r0w1，↓r1w0，↑r0。|
|13|[fault_injector](../ip/fault_injector/SPEC.md)|test|按接受拍相位进行XOR/stuck0/stuck1；非法模式返回原值并报错。|
|14|[stream_metrics](../ip/stream_metrics/SPEC.md)|test|16槽时间戳队列，计数接受/消费/阻塞，测顺序流延迟和输出间隔。|
|15|[capture_replay](../ip/capture_replay/SPEC.md)|test|主机空闲加载96位刺激；同步RAM预取，II1回放；原始192位响应保存/同步读回。|
