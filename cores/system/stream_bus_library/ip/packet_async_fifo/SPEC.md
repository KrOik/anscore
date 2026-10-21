# packet_async_fifo

模块：`sys_packet_async_fifo`。版本：1.0.0。

同步双时钟RAM整包存储，TLAST后提交长度/请求翻转，末拍消费后确认。

共同复位；最多1包在途；超DEPTH包整体丢弃。长度总线必须在请求/确认往返期间稳定。硬件夹具采用同源同频时钟。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores packet_async_fifo
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
