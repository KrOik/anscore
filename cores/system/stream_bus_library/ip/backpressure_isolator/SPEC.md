# backpressure_isolator

模块：`sys_backpressure_isolator`。版本：1.0.0。

两拍存储，s_ready仅取决于寄存器占用；占用1时持续II1。

占用满时本周期即便下游释放，上游仍等下一周期。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores backpressure_isolator
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
