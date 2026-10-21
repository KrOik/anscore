# axi_lite_interconnect

模块：`sys_axi_lite_interconnect`。版本：1.0.0。

16位地址，4个4K窗口；独立AW/W收集与读通道；未映射返回DECERR。

每方向最多1笔在途；无突发；PROT/WSTRB保留；下游无响应需结合监控器处理。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores axi_lite_interconnect
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
