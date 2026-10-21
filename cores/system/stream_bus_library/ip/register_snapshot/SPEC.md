# register_snapshot

模块：`sys_register_snapshot`。版本：1.0.0。

就绪时一次采样整组live、64位周期和递增snapshot_id。

一个弹性输出槽；停顿期间保持全部输出。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores register_snapshot
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
