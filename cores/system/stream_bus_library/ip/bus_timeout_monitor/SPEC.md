# bus_timeout_monitor

模块：`sys_bus_timeout_monitor`。版本：1.0.0。

握手后计龄；响应在截止边缘优先；超时保持在途等待真实响应。

被动监控器不生成虚假完成；limit0禁用截止；年龄饱和65535；clear用于空闲计数清零。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores bus_timeout_monitor
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
