# 本机开发与调试

## 固定环境

2026-11-11 配置：

| 项目 | 当前值 |
| --- | --- |
| macOS | 27.3 (26C5035r) |
| Xcode | 27.2 (27B52) |
| Developer Directory | `/Applications/Xcode.app/Contents/Developer` |
| 模拟器运行时 | iOS 27.2 (24B8117)，arm64，已注册为 Ready |
| 专用设备 | XHS Dev iPhone 17 |
| UDID | `356DF9C3-F74F-41A9-8FE2-60A59058E94D` |
| 图形入口 | `/Applications/Xcode.app/Contents/Applications/DeviceHub.app` |
| 构建和测试输出 | `.build/ios-dev/`（Git 忽略） |

此版 Xcode 使用 Device Hub 显示模拟器，不要再启动旧路径 `Contents/Developer/Applications/Simulator.app`。

旧设备曾在启动时返回 `Data Migration Failed` 并停在苹果标志，下载器尚未启动。刷新 CoreSimulator 服务未消除问题。重建设备首次初始化虽然以 `Finished` 结束，再次启动仍失败。按用户要求删除了旧设备及 iOS 27.0 运行时，改由 Xcode Components 下载官方新副本，并删除安装后自动生成的其他模拟器，仅保留上面的专用设备。实体 iPhone 和 iPad 未改动。

旧、新运行时的官方 `simctl runtime verify` 均返回 `-67054 / a sealed resource is missing or invalid`。因此，这个结果在当前宿主环境上不能单独证明运行时损坏；不要据此循环下载或绕过签名校验。

Xcode 的 Get 此次排入了两个不同构建的 iOS 27.2 Simulator：`24B8117` 和 `24B91016s`，各约 8.32 GB。第一项已安装；第二项的具体用途尚未确认，已通过退出 Xcode 停止，未安装第二份运行时。后续先验证现有运行时，不重复点 Get。

后续复用专用设备，不在每轮测试后关闭、克隆或重建。实际观察到退出 Device Hub 会连带关闭设备，因此测试期间保持 Device Hub 打开，只停止应用或测试。

这台 Mac 为 8 GB 内存。诊断期间曾有约 8 GB 交换空间占用和很高的系统负载；编译限制为 2 个并发构建操作，测试只使用一个模拟器，不自动重试。

本机 Xcode 的 General → Test Parallelization → Testing on Simulator 已选 `1 simulator`，对应 `IDEMaxParallelTestingSimulators=1`。编译并发偏好 `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` 已设为 `2`，原值未设置。恢复编译自动并发可执行：

```sh
defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks
```

恢复模拟器自动并发可在 Xcode 同一菜单选回 Automatic。上述调整与脚本参数同时覆盖图形界面和命令行工作流。

## 日常入口

在仓库根目录执行：

```sh
./scripts/ios-dev.sh run
./scripts/ios-dev.sh test
./scripts/ios-dev.sh test DestinationFlowTests
./scripts/ios-dev.sh ui XHS_Downloader_iOSUITests/testLaunchShowsTaskCenter
```

- `run`：Debug 编译、覆盖安装并启动应用，保留该开发设备中的数据。打开 Device Hub 选中专用设备即可交互。
- `test`：默认仅运行 `MediaKindDetectionTests` 的 3 项检查。可传一个或多个测试类或 `类/方法`。
- `ui`：必须指定用例，不顺带启动整套 UI 测试。
- `test all`：明确需要时才运行全部单元测试。
- 脚本不自动重试、不删除数据、不在结束时关闭模拟器。启动日志出现迁移失败时立即停止。
- 启动最多等待 180 秒，超时即停止，不接着编译或启动测试。
- 关闭失败时自动收集完整模拟器诊断包（`-collect-test-diagnostics never`）。本次堆栈已确认 Xcode 会在启动失败后阻塞于 `simctl diagnose`，显著增加等待与磁盘压力；普通失败信息、测试结果和系统崩溃日志仍保留，需要完整诊断时再手动采集。
- 每次测试输出独立的 `.xcresult` 和同名 `.log`；编译启动的日志为 `build.log`。

需要其他设备时显式覆盖，不要同时运行多个测试命令：

```sh
XHS_SIMULATOR_UDID=其他设备的UDID ./scripts/ios-dev.sh test MediaKindDetectionTests
```

图形调试时打开项目，选择 `XHS_Downloader_iOS` 和运行目标 `XHS Dev iPhone 17`，点击 Run；本轮已确认暂停、调用栈和继续可用。命令行 `run` 用于启动，不自动附加 LLDB。

Xcode 的 `XHS_Downloader_iOS` scheme 默认仅启用单元测试；`XHS_Downloader_iOS-UI` 仅启用 UI 测试。两个 scheme 的测试目标都关闭了并行设备执行。Swift Testing 的进程内并发仍由测试代码自身的 suite traits 决定。

后续修复先跑直接受影响的用例，通过后结束验证；没有新的失败证据时，不循环重跑，不扩展到全量回归。

## 本轮验证结果

重启 Mac 后，同一份 iOS 27.2 运行时上的 iPhone Air 仍迁移失败；清除设备重新初始化也未解决。其 35 个迁移插件均报告成功，但最终迁移结果为失败，具体原因尚未定位。改建 iPhone 17 后，首次初始化约 72 秒，最终迁移成功；失败的 Air 已删除，仅保留当前开发设备，实体设备未改动。对照记录为 `.build/dev-environment/migration-comparison.json`。本轮重启后没有再次下载运行时。

- `./scripts/ios-dev.sh run`：Debug 编译、安装及正常启动成功，已在 Device Hub 看到完整应用首页，版本为 1.1.0 (22)。
- 默认定向测试的 3 项 `MediaKindDetectionTests` 全部通过：HEIC 静态图、真实配对 MP4、不存在的文件。测试执行约 1.127 秒，宿主启动与连接约 73 秒。
- 有效结果：`.build/ios-dev/Test-20261111-005223.xcresult`；同名 `.log` 含 `TEST SUCCEEDED`。没有运行完整回归或 UI 自动化。
- Xcode 调试连接成功：Run 后显示应用 PID、CPU 和内存；点击暂停后看到 Thread 1 调用栈与 SIGSTOP，再继续后恢复 Running。首次调试初始化较慢，采样中曾等待 SDK 路径查询；没有更改系统安全权限。独立命令行 LLDB 两次附加超时，日常调试使用已验证的 Xcode Run 入口，不将 CLI 超时当成整个调试服务不可用。

首次应用慢启动采样显示主线程处于正常 UIKit 事件循环，未证明持久化死锁。日志中的主线程等待 QoS 提示及 `TaskFocus` 导航位置提示属于后续产品排查事项，本次没有修改业务源码、动画或关闭检查器。

重启前的失败结果 `.build/ios-dev/Test-20261110-234010.xcresult` 保留作诊断，不能计作通过。旧、新运行时相同的签名校验错误也不能替代实际启动结果。

## 崩溃弹窗与恢复

最近诊断报告大量来自模拟器系统服务，例如 `splashboardd`、`dtdeviceinfod` 和 Siri 服务，常见终止原因是 `LIBXPC / XPC_EXIT_REASON_SIGTERM_TIMEOUT`，集中出现在模拟器关闭时。它们不能算作下载器应用崩溃；也存在其他类型的系统服务报告，需按实际进程和堆栈判断。

当前 macOS 用户已设置：

```sh
defaults write com.apple.CrashReporter DialogType -string none
```

此设置关闭当前用户所有应用的“意外退出”弹窗，范围不限于模拟器。没有卸载 ReportCrash、关闭诊断日志或更改向 Apple 提交诊断的设置。日志仍在 `~/Library/Logs/DiagnosticReports/`，Xcode 测试错误也仍写入结果包。

修改前 `DialogType` 不存在。恢复原先的系统默认行为：

```sh
defaults delete com.apple.CrashReporter DialogType
```

修改前的完整偏好备份保存在本地 `.build/dev-environment/CrashReporter-before-20261110.plist`，不要用完整导入覆盖未来产生的其他偏好，恢复这个键即可。
