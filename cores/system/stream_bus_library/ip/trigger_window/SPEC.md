# trigger_window

模块：`sys_trigger_window`。版本：1.0.0。

同步环形RAM；触发拍前最多PRE拍，后POST拍；冻结后读出且保持停顿数据。

DEPTH是2的幂，PRE+POST+1≤DEPTH；单次arm；WIDTH可携带时间戳。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores trigger_window
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
