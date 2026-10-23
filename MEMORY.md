# Current State

- SwiftUI iOS App，使用 CoreBluetooth 读取沃莱 Scale27 协议体脂秤，并可将结果写入 HealthKit。
- 最低系统版本为 iOS 16；项目不依赖第三方包。
- GitHub 仓库：`Nathanielguo/ant-afu-scale`。

# Architecture Decisions

- 测量和身体成分计算均在设备本地完成，不引入云端服务。
- 蓝牙与 HealthKit 真正可用性必须在已签名的 iPhone 真机上验收。

# Known Issues

- CoreBluetooth 和 HealthKit 仍需在已签名 iPhone 与真实体脂秤上验收；模拟器无法完成这部分验证。

# Recent Changes

- 2026-08-12：创建项目级工作规则与精简项目记忆；完善连接超时、授权时机、资料编辑一致性和最近测量持久化。
