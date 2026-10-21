# capture_replay

模块：`sys_capture_replay`。版本：1.0.0。

主机空闲加载96位刺激；同步RAM预取，II1回放；原始192位响应保存/同步读回。

默认深度256；主机须写全引用行；输入/输出长度可不同；显式长度错误和截止超时；无RAM内容初始化。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores capture_replay
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
