# atomic_config

模块：`sys_atomic_config`。版本：1.0.0。

按字节写影子寄存器；commit包含同边缘写；apply_safe后整组更新。

等待应用时write_ready/commit_ready低；WORDS为2以上2的幂。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores atomic_config
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
