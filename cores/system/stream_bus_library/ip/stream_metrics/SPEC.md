# stream_metrics

模块：`sys_stream_metrics`。版本：1.0.0。

16槽时间戳队列，计数接受/消费/阻塞，测顺序流延迟和输出间隔。

适合顺序1:1流；输入超过16个未完成报错。聚合/拆分/丢弃流只能使用计数与replay总周期，延迟不适用。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores stream_metrics
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
