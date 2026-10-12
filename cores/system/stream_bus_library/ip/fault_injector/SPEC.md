# fault_injector

模块：`sys_fault_injector`。版本：1.0.0。

按接受拍相位进行XOR/stuck0/stuck1；非法模式返回原值并报错。

仅功能注错；不是物理故障或安全防护证明；period0每个启用拍触发。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores fault_injector
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
