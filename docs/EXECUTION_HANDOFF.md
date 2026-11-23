# 新会话执行提示词

在新会话使用执行模式，直接发送下面这段内容即可。完整计划已在项目中，不需要复制此前聊天内容。

```text
请直接实施 /Users/mio/xhs/XHS_Downloader_iOS/docs/IOS_1_1_0_PLAN.md 中的完整补完计划，不要重新规划或只给建议。

开始前先阅读：
1. 适用的 AGENTS.md。
2. /Users/mio/xhs/XHS_Downloader_iOS/docs/CHECKPOINT_BUILD16.md。
3. /Users/mio/xhs/XHS_Downloader_iOS/docs/IOS_1_1_0_PLAN.md。
4. /Users/mio/xhs/XHS_Downloader_iOS/docs/IMPLEMENTATION_PROGRESS.md，其中记录了暂停时的初步改动、失败构建和未接入部分。

当前满意基线已提交：
- 提交：8d622fbc23bdc46bbe1067c9daa59fe9a41d21bc
- 标签：checkpoint/ios-build16-before-1.1.0

先检查工作区并保留全部已有修改。feat/ios-1.1.0-completion 分支已经建立并包含未完成的 WIP，请在该分支接续，不要切回基线标签或重新初始化项目。WIP 尚未编译通过，不是已交付版本；先检查进度文档和 diff，修正编译、默认策略过滤与持久化接入。

用户对当前版本比较满意，特别注意保护当前外观、跟手弹簧、速度投影、可中断并重新接管的转场。计划里的旧动画问题作为回归场景；只有当前仍能复现时才针对性修复，不要默认重写动画。

按计划完整实施，常规设计和技术选择自行决定，无需逐项确认。可以按依赖顺序分步开发并建立清晰的本地提交，但不要把最终功能范围拆成几次交付，也不要只完成一部分就收尾。

参考项目：
- /Users/mio/xhs/XHS_Downloader_Android
- /Users/mio/xhs/XHS-Downloader

保留 Live Photo 和 HDR 原件处理。数据迁移前备份，Git 代码回退不能替代用户数据备份。做与改动相称的验证；模拟器启动失败时不要反复等待，记录待测项并继续可完成的检查和编译，不得将编译成功写成真机验证通过。

最终在本地提供完整 IPA、SHA-256、安装说明、完成情况与实际验证结果，保持分享扩展及 App Group 自签要求。不要发送 QQ，不自动 push 或发布。
```
