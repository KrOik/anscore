# timestamp64

模块：`sys_timestamp64`。版本：1.0.0。

记录输入接受边缘之前的64位计数；load优先改变随后计数。

同时load和样本接受时样本使用旧计数；64位自然回绕；单输出弹性槽。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores timestamp64
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
