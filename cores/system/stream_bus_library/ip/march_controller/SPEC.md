# march_controller

模块：`sys_march_controller`。版本：1.0.0。

完整March C-：↑w0，↑r0w1，↑r1w0，↓r0w1，↓r1w0，↑r0。

每地址10条命令；写也需要响应；比较错误继续，总线错误/超时终止done且errors>0；不声明故障覆盖率认证。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores march_controller
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
