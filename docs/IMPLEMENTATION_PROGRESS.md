# 实施进度：1.1.0 已完成

更新日期：2026-11-10。本文替代此前的暂停交接记录。

## 结论

1.1.0（build 22）已完成并交付到本地：`dist/XHS-Downloader-iOS-1.1.0-22-unsigned.ipa`。
完成范围、验证结果与已知限制见 [RELEASE_1_1_0.md](RELEASE_1_1_0.md)。

## 分支与提交

- 开发分支：`feat/ios-1.1.0-completion`。
- 用户满意基线：`8d622fbc23bdc46bbe1067c9daa59fe9a41d21bc`，标签 `checkpoint/ios-build16-before-1.1.0`。
- 恢复的 WIP：`173e802`。
- 完整实现：`0590f60` 及后续提交。
- 未推送远程，未发送 QQ。

## 交接时遗留问题的处理结果

| 交接文档列出的问题 | 处理 |
| --- | --- |
| `WebSession.swift` 编译失败（`main actor-isolated 'trusted'`、`CocoaError` 缺 CoreData） | 改为 `nonisolated static trusted`，新增 `ProxyConfigurationError` 替代 `CocoaError` |
| 协调器按全部媒体下载，未接入 `DownloadPolicy.includes` | 已在 `run(taskID:)` 按策略过滤，默认不下载封面/评论图 |
| `DownloadPolicy.applying` 未被调用 | 已在下载链路对每个媒体调用，支持手动规格选择 |
| 逐资源结果未用于进度聚合 | `ResourceResult` 逐槽位记录，详情页展示，支持只重试失败项 |
| 高频进度写库未节流 | 进度走 700ms 合并写入；状态/选择/保存结果立即落盘 |
| 无浏览器/账号 UI | 新增 `BrowserView` 与设置账号卡，持久会话共享 cookie |
| `loadError` 未展示 | `DownloadTaskStore.loadError` 保留旧数据并在持久化失败时提示 |
| 命名时区隐式读取 | 改为显式 `NamingPreferences.timeZone`，随任务快照 |
| 缺 4 个本地化 key | 已补齐，并新增 1.1.0 全部新界面文案（当前 320 key，en/zh-Hans/zh-Hant） |
| 无测试 | 新增 `CompletionFeatureTests.swift`，覆盖策略、分组、归档、命名时区、备份、库特性、入口行为 |

## 审核后修复（build 18）

第一轮交付被审核指出六项 P1 与若干 P2 问题，均已修复并有回归测试：

| 审核问题 | 修复 |
| --- | --- |
| 移除已完成会删除笔记资料 | 笔记改为独立的 `NoteStore`，历史操作只删任务；首次启动从旧任务迁移 |
| 默认相册媒体的原件 ZIP 为空 | 新增 `PhotoOriginalExporter` 从 Photos 读取原件，Live Photo 保留两组件 |
| 照片与文件目录不可用仍显示完成 | 逐目的地 `DestinationResult`，任务按目的地判定完成，保留暂存以便补存 |
| 智能跳过漏保存相册且只按文件名 | 校验文件非空与大小一致；只跳过文件目的地并关联已有路径 |
| Live Photo 合成失败算完成 | 单独记录 `merged`/`componentsOnly`，失败可重试 |
| 浏览器下载本篇未用页面数据、丢参数 | 直接读取页面结构化笔记并保留 `xsec_token` 等参数 |
| 纯文案笔记打不开 | 无封面时直接打开阅读器并提供删除路径 |
| Files 媒体未进笔记、无权限全屏阻断 | `LibraryMedia(record:)` 解析文件路径；改为顶部提示条 |
| 网络设置不生效 | 每个任务按快照建下载器；代理媒体走前台会话 |
| 策略非提交时快照 | 提交时写入 policy、downloadInstant、命名时区 |
| 备份范围与脱敏不足 | 备份 v2 含笔记/合集/喜欢/收藏/备注/设置/头像；导出脱敏 |
| 只重试失败项不刷新地址 | 重新解析并保留已成功槽位 |
| 任务字节在资源间跳动 | 按资源聚合 |
| 写入发布时间无实现 | 应用到 Photos 创建日期与归档文件时间 |
| 检查更新不检查 | 读取发布版本做数值比较 |
| loadError 不展示 | 启动与设置页立即提示 |

## 第二轮审核后修复（build 19）

| 审核问题 | 修复 |
| --- | --- |
| 完成判定用 `archive != nil`，目录失败仍报完成 | 改用用户请求的 `wantsFiles` |
| Files-only 无媒体记录、预览只认 PHAsset | 调用 `recordArchivedAsset`；预览与查看器支持 `file:` 路径 |
| Files-only Live Photo 永久失败 | 合并要求仅在 Photos 为目的地时生效 |
| 仅保存笔记不写笔记库 | `saveNoteOnly` 调用 `syncNote` |
| 命名设置与任务快照脱节 | 设置直接编辑 policy；旧 @AppStorage 值启动时导入 |
| 迁移未映射旧 UUID 的喜欢/收藏/合集 | 一次性身份映射迁移 |
| 详情页与信息流收藏状态分裂 | 统一到协调器 |
| 备份笔记分支未脱敏 | `redactedNote` |
| ZIP 读取失败静默漏文件 | 记录缺失并在清单与提示中报告 |
| 补存重复执行成功目的地 | 按目的地状态跳过 |
| 重选目录不修复旧任务 | `reauthorizeArchiveDirectory` |
| 智能跳过只比名字与大小 | 增加 SHA-256 身份校验 |
| 每任务新建限速器使间隔失效 | 协调器级共享 pacer |

关键教训：上一轮测试只验证模型，没有验证调用者。本轮新增的端到端测试用桩网络驱动真实协调器，第一次运行就抓出三个缺陷（完成判定参数、Files 媒体记录缺失、偏好读错 UserDefaults）。

## 第三轮审核后修复（build 20）

按用户要求本轮停止测试直接交付，Release 编译与测试构建通过，未跑完整回归。

| 审核问题 | 修复 |
| --- | --- |
| 合成失败后重试不重新合成 | 跳过条件加入 `livePhotoOutcome == .merged` |
| Files 媒体显示不完整 | 封面读文件、查看器识别视频、Live Photo 播动态组件 |
| 智能跳过丢 Live Photo 视频路径 | 按条目键逐组件收集路径 |
| 备份泄露主页 token 与 file: 绝对路径 | `redactedMetadata` / `redactedAsset` |
| Files 分享删除走相册 | 分享复制文件、删除区分来源 |
| 补存成功不写回归档路径 | `attachArchivedPaths` + `mergeAssets` 刷新字段 |
| ZIP 漏组件仍报完整、清单错误 | 逐组件校验、容器识别视频、逐文件体积 |
| v1 备份导入无笔记 | 导入后投影笔记 |
| 迁移未回填 noteKey | 回填并按身份删除 |
| 作者修复入口失效 | 按笔记身份修复并同步 |

## 第四轮审核后修复（build 21）

按要求只做与改动直接相关的最小验证，未跑完整回归。

| 审核问题 | 修复 |
| --- | --- |
| HEIC 被 `ftyp` 判断当视频 | `MediaFileValidator.isVideoFile` 用 ImageIO 先解码，失败再看 UTType |
| 文件视频打不开 | 查看器允许无静态帧的视频，用首帧海报 |
| Live Photo 封面读错路径 | 封面按换行拆分取可解码组件 |
| 归档重名丢路径 | `ArchiveResult.paths` 按资源键返回 |
| 作者修复被占位文本挡住 | `hasKnownAuthor` |
| 目录失败不保留笔记 | 异常处理调用 `syncNote` |

## 第五轮审核后修复（build 22）

| 审核问题 | 修复 |
| --- | --- |
| 纯视频封面无限加载 | 取首帧作封面，失败显示视频占位 |
| 测试仍用假 MP4 | 改为读取项目真实 `livephoto-motion.mp4` |

针对性验证 11 项全通过（MediaKindDetectionTests 3 + DestinationFlowTests 8）。

## 本次额外修复

- `RequestPacer` 由进程单例改为每个 `XHSDownloader` 一个实例：一个任务的请求积压不再拖慢无关任务，也让测试互不干扰。间隔为 0 时不再占用时间槽。
- 并行跑测试时 `SelectionQueueTests` 与 `LivePhotoNoteRegressionTests` 曾因资源时序偶发失败；串行运行全部通过，已记录在交付文档中，未当作真机验证。

## 后续可做

- 真机验证账号登录、网页提取、真实下载、Live Photo/HDR 保真、后台传输、通知点击与分享扩展跳转。
- 小红书改版后同步网页选择器与解析字段。
