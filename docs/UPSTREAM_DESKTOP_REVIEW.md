# 电脑版最上游对比：接口与用户功能

对比日期：2026-11-11。本报告沿实际调用链核对代码，区分已实现能力、部分覆盖和不适合原样搬到 iOS 的桌面能力。

## 移动端范围决定（2026-11-11）

用户已明确不需要电脑联动。以下决定取代后文对比表中的扩展建议；对比表记录能力差异，不等于开发任务清单。

产品重心是：分享或粘贴笔记后可靠保存，方便阅读、整理和分享原件。默认保留原件与 Live Photo/HDR，常用路径简单，低频操作留在现有详情或菜单中。

### 已实施范围（build 25）

1. **修正现有解析与登录兼容性。** 补 URL 派生资源键、动态流全部编码键和备用地址、已知水印规格的候选排序、RedNote 原域会话。它们改善现有下载行为，不新增设置页或要求用户选择编码。已知水印标记仅作为排序线索，没有标记不代表已验证无水印；保留可用候选。
2. **讲清保存结果。** 复用现有逐目的地结果，在相关任务中说明照片/文件分别是否保存；有失败时提供既有补存操作。Files 结果提供可用的系统打开或分享入口。优先调用现成系统能力，不能直接定位目录时提供文件本身，不做自建文件管理器。
3. **轻量批量复制。** 仅在已有多选菜单加入“复制所选链接”，复用现有复制方法和数量提示。没有选择时不新增常驻按钮，不另做“导出全部/按每种状态复制”的工具页。

上述功能沿用当前页面和数据来源，不改笔记布局、转场弹簧、Live Photo 合成或 HDR 显示链路。

build 25 执行结果：

- 正文、封面、评论图片均可从 URL / infoList 回填资源键，网页签名与裁剪后缀不进入原件键；保留主键和 URL 派生的原件回退。格式偏好只应用到普通图片，不把 Live Photo 静态组件改成有损格式。
- 视频与 Live Photo 动态流遍历全部编码键，支持只有备用地址的条目，已知水印规格降序保留作回退；手动选定规格仍优先。没有新增设置。
- RedNote 保留自己的域名、访问参数和会话；按 Cookie 存储的实际域/路径选择 Cookie，不跨域复制登录凭据。短链也复用会话开关与请求节流。
- 任务详情直接显示照片/文件分别保存的数量，失败时提供补存入口；资源和文案文件可分享已保存原件。文件复制期间持有既有目录授权，分享使用系统面板，未创建文件管理器。
- 笔记多选区的更多菜单提供“复制所选链接”，按笔记去重，跳过没有来源的相册条目，复用剪贴板自下载抑制。
- 本轮没有修改 `NoteHeroPresentation.swift`、`NoteReaderView.swift`、`MediaInteraction.swift`；它们与 build 24 工作区逐文件 SHA-256 相同。没有实施排除项。验证与包信息见 [RELEASE_1_1_0.md](RELEASE_1_1_0.md)。

### 本次不纳入

- **电脑联动、API/MCP 客户端、WebSocket、CLI 或 Docker：排除。** 不保留“以后顺便接入”的任务。
- **远端互动计数：不做。** 离线保存的数字很快过时，与本机喜欢/收藏容易混淆，不增加刷新请求或数据面板。
- **最后更新时间：暂不单独补。** 当前发布时间和保存时间满足阅读需求；以后若做笔记内容更新，再随该流程保存更新时间。
- **账号主页全量下载、自动滚动、评论全量采集、搜索用户抓取：不做。** 内置浏览器保留当前已加载笔记的选择导入，不扩成采集工作台。
- **列表类型分类与全局统计面板：不做。** 使用现有搜索、分组和资源结果；不为与电脑版对齐增加第二套入口。
- **数据库分页重构和自建续传框架：暂不做。** 有实际慢启动、大库卡顿或可复现的恢复失败时，再针对瓶颈处理；现有恢复数据的正确性问题仍属于应修复的缺陷。
- **自动重命名历史目录：不做。** 新下载沿用当前资料与命名规则，已保存文件不随作者改名自动移动。
- **更多格式、编码和网络开关：不增加。** 现有策略能表达的继续复用，默认优先原件；本轮只修现有选项无效的情况。

验证限制：解析修正使用直接覆盖实际策略调用的少量样本；保存结果与批量复制只检查受影响流程；一次编译。没有新失败证据不扩大为完整回归，不循环启动模拟器。若本轮没有真机条件，明确交付未实测项，不以无关测试代替。

## 对比基准

以下接口与功能差异以审核时的 build 24 为基准；build 25 的补齐结果以上方执行记录为准，历史差异不应继续当成未完成任务。

- 最上游：[JoeanAmier/XHS-Downloader](https://github.com/JoeanAmier/XHS-Downloader)，正式版仍为 [2.8](https://github.com/JoeanAmier/XHS-Downloader/releases/tag/2.8)，2026-09-12 发布。
- 同时核对正式版之后的 `master`，HEAD 为 `dfad51b3d1aac55866802007544f9390ad21553f`，最新提交时间为北京时间 2026-11-06 18:52。工作区下载的源码没有 `.git`；本轮用独立临时 Git 副本核对提交。应用、图片、视频、请求、状态转换、GUI 后端、用户脚本与鉴权等核心文件与当前 HEAD 字节一致，没有覆盖工作区源码。
- 安卓参照为工作区 `bc810a690d3574efb416bc915d3b5c7fa4da3288`，2026-11-07 的公开小红书号与日期格式提交。本轮没有把安卓本地 HEAD 声称为远端所有分支的最新提交。
- iOS 为 build 22 基础上的 build 23/24 工作区。主下载路径是 `DownloadCoordinator → resolveNote → ResolvedNote.swift → RemoteMedia.applying → 下载/保存`，不能用旧 `parsePostDetails` 的能力代表当前应用。
- 三个项目各自实现解析和下载，没有直接把 Python 上游作为 iOS 内嵌运行库；这里的“上游”是行为与协议参考。

## 正式版之后的重要更新

| 提交 | 变化 | 对 iOS 的意义 |
| --- | --- | --- |
| `dbad559`，11-06 | 用户脚本补充 `fileId` / `urlPre` 图片来源及 RedNote 首页识别 | 图片键回退和网页入口都应检查 |
| `a09a3d6`，11-05 | 脚本视频规格选择、偏好及交互调整，取消自动滚动 | 适合借鉴已加载内容选择与规格说明，不需要自动滚动爬取 |
| `db9f991`，10-30 | 图片下载按 `fileId → urlDefault → urlPre` 提取资源键 | iOS 下载地址已覆盖，指定格式时仍有键缺失问题 |
| `0705a4a`，10-18 | 支持状态对象里的 `new Set([])` | iOS 使用 JSContext 执行状态脚本，已覆盖，无需照搬字符串替换 |
| `1cc5600`，10-14 | Cookie 增加短链域 | iOS 应核对真实 Cookie 域与重定向，而不是把登录 Cookie 任意复制到所有域 |
| `6864f8b`，10-09 | 状态解析由 YAML 改为 JSON，并处理控制字符 | iOS 解析机制不同，已支持 JS 转义；重点是样本覆盖 |
| `2ce39c4`，09-30 | GUI 按任务状态复制链接 | iOS 当前只有单任务复制，确实缺少批量复制 |
| `3df99d2`，09-27 | API、MCP、脚本增加鉴权 | 如果以后接入电脑，必须使用实际新协议 |
| `69a68ca`，09-19 | 可配置请求间隔均值 | iOS 已有共享 RequestPacer 和设置，固定间隔与上游随机均值语义不同 |

提交入口：[正式版之后的提交历史](https://github.com/JoeanAmier/XHS-Downloader/commits/master/)。以上更新已包含在本地最上游副本中。

## 解析及接口覆盖

| 项目 | 最上游现状 | iOS 现状与差异 |
| --- | --- | --- |
| 短链与新域名 | `xhslink.com`、`xhslink.cn`，小红书与 RedNote | 域名识别已覆盖；短链首跳没有显式使用手动 Cookie 或请求节流。RedNote 正文请求被改到小红书主域，可能丢失只在 RedNote 建立的会话，需要独立修正域名路由 |
| 图片地址 | 从 `fileId`、默认地址、预览地址提取键，再构造 CDN 或格式地址 | 正文、封面、评论图片均保留多候选，已支持 `fileId` / `urlPre`；但 `fileKey` 只从 `fileId` 写入，只有 URL 的图片指定格式时会直接沿原件候选下载 |
| 指定图片格式 | PNG、WebP、JPEG、HEIC、AVIF，自动格式 | iOS 策略已覆盖。应补齐 URL 派生资源键，再确认返回格式；Live Photo 原件保真应单独保持，不能为追求格式一致破坏 HDR 或配对 |
| 状态脚本 | JSON 转换，处理 Map、Set、undefined、控制字符；手机/桌面状态分支 | iOS JSContext + 按目标笔记 ID 匹配已覆盖，且避免拿页面上无关笔记。不需要引入 Python/YAML 或重新做解析框架 |
| 原始视频与规格 | 原始 key 优先，否则按分辨率、码率、体积排序；遍历全部编码键 | iOS 规格表遍历全部键，支持原始、清晰度、码率、小体积、H.264 兼容与手动规格。基础候选/Live 动态候选仍只遍历 h265/h264/av1/h266，新编码键可能漏掉；规格构造也会忽略只有备用地址的条目 |
| 视频体积偏好 | 当前 Python `size` 排序选最大的文件 | iOS 的“小体积”选最小，符合其按钮含义。属于设计差异，不能按同名字段直接映射 |
| Live Photo | 下载静态与动态组件，遍历 stream 的全部键 | iOS 保留两组件并提供 Apple 合成、组件及组合模式，已超出桌面；动态候选覆盖需要上述补齐。安卓会标记已知水印规格，iOS 尚未保存这些标记，也没有据此降级排序 |
| 备用地址 | 动态流优先备用地址再主地址 | iOS 多候选回退已存在，通常主地址先。应保留所有合法地址，无需仅为顺序差异重写下载器 |
| 元数据 | 标题、正文、作者、发布时间、更新时间、标签、点赞/收藏/评论/分享数 | iOS 作者、头像、UID、公开 ID、正文和话题已覆盖；缺少远端互动计数及最后更新时间。安卓已存储这些字段 |
| 评论与账号批量 | 脚本提取页面列表；代码存在账号请求辅助类 | `UserPosted.run` 仍是空实现，不能声称已完成服务端账号全量分页。iOS 评论图片只处理已提供的数据，没有自动抓全评论；这不是本轮发现的上游成熟能力缺失 |
| HTTP 行为 | curl_cffi 浏览器模拟，部分路径关闭 TLS 校验 | Swift 原生网络不同，真实登录和网站响应仍需样本验证。保持系统 TLS 验证，不照搬 `verify=False` |

实现依据：上游 [image.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/application/image.py)、[video.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/application/video.py)、[converter.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/expansion/converter.py)、[request.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/application/request.py)。iOS 对应实现见 `/Users/mio/xhs/XHS_Downloader_iOS/XHS_Downloader_iOS/ResolvedNote.swift`、`DownloadPolicy.swift`、`XHSDownloader.swift`；安卓解析见 `/Users/mio/xhs/XHS_Downloader_Android/app/src/main/java/com/neoruaa/xhsdn/data/xhs/XhsNoteParser.kt`。

## 电脑版功能与 iOS 使用体验

| 能力 | iOS 覆盖情况 | 适合 iOS 的设计 |
| --- | --- | --- |
| 多链接入队、剪贴板监听 | 已有四入口、统一导入和幂等入队 | iOS 在前台/回到应用时检查剪贴板，提供开关。系统不允许照搬桌面常驻后台读取剪贴板 |
| 任务状态、进度、取消与清理 | 已有任务分组、逐资源状态、批量暂停/继续/重试、目的地独立结果 | 保留现有任务中心，只补齐缺少的批量链接操作和汇总 |
| 按状态复制任务链接 | 部分：单任务复制已有，按筛选/选择批量复制未见 | 筛选结果与选择菜单增加“复制链接”，复制前显示数量；使用既有剪贴板方法避免触发自下载 |
| 历史查询与大列表 | 搜索已有；任务仓库启动时全量载入 JSON payload，筛选在内存 | 数据量大后会慢。需要时改为数据库过滤和分页，不应只给 UI 加一个假分页按钮 |
| 下载成功/失败/跳过汇总 | 有单任务/逐资源结果；桌面有全局汇总 | 任务分组显示数量，批量操作结束提示成功/失败/跳过数，避免制造另一套统计存储 |
| 文件断点续传 | iOS 后台会话已有 resumeData | 属于部分覆盖：代理模式走前台，签名 URL 刷新后缓存键变化。不承诺所有路径都接续；按资源身份关联恢复信息，继续让 URLSession 管理网络续传 |
| 单独目录与直接打开目录 | Files 归档、作者/笔记目录已有 | 在保存结果提供真实位置与文件分享/系统打开入口；目录授权失效时走既有重选与补存流程 |
| 作者备注与改名 | 本地备注已有；任务命名采用快照 | 上游会随昵称变化改旧目录。iOS 不应默认移动用户文件；可提供显式“更新作者资料”，旧文件名保持，若以后做改名需预览后操作 |
| TXT/Markdown 信息归档 | 已有正文与元数据归档 | 补充远端计数和更新时间，注明是保存时快照；本机喜欢/收藏与远端计数分开表达 |
| 下载记录与作品数据数据库 | SwiftData 任务、独立笔记库、JSON/CSV/ZIP/备份已有 | 不需要为 SQLite 名称一致再加数据库；保留笔记与任务分离和脱敏导出 |
| 浏览器登录与 Cookie | 持久 WKWebView、账号卡、手动 Cookie 已有；build 23 桌面模式、24 即时同步 | 上游从浏览器抽 Cookie 已在 README 划掉，不能当作稳定领先功能。iOS 继续维护自身网页登录会话 |
| 网页批量提取 | iOS 当前页已加载笔记链接最多 200 条、选择导入 | 上游脚本范围更丰富：推荐、发布、收藏、点赞、专辑、搜索笔记和用户。可增加列表类型说明、用户链接结果及选择预览，沿用已加载数据，不自动无限滚动 |
| 单篇按序号/规格下载 | 已有选择内容与视频规格 | 保留原生选择页，补尺寸/编码/体积的清楚说明；远端体积未知就显示未知 |
| 脚本与电脑联动 | 未实现桌面 WebSocket 客户端 | 用户明确不需要，排除出 iOS 范围 |
| API、MCP、CLI、Python、Docker | iOS 未提供同等服务端 | 属于电脑部署和自动化能力，排除出 iOS 范围 |
| 本机笔记阅读与媒体体验 | iOS 有双列笔记、正文话题、作者主页、本地合集/喜欢/收藏、多选删除、分享 | 桌面并无同等原生读图体验，属于应继续保留的 iOS 优势 |
| 原生 Live Photo、HDR、触感和系统分享扩展 | iOS 已有对应代码路径 | 桌面下载组件不等于 Apple Live Photo 合成，不能反向削弱这些能力；实际显示与配对以真机结果为准 |

桌面实现依据：[GUI 后端](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/GUI/backend.py)、[历史数据库](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/module/recorder.py)、[作者目录映射](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/module/mapping.py)、[信息归档](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/module/note_info.py)。

## 上游电脑协议记录（仅供对比，不纳入 iOS）

1. HTTP：默认端口 `5556`，`POST /xhs/detail`，需要 `Authorization: Bearer <token>`，缺失/无效返回 403。参数为 `url`、`download`、`index`、`cookie`、`proxy`、`check_record`，返回 `message/params/data`。接口只处理一个链接，`download=true` 保存到电脑，不代表文件已回传手机。
2. MCP：可选依赖 `fastmcp>=4.1.0`，同端口 `/mcp/`，提供 `get_detail_data(url)` 和 `download_detail(url,index,return_data)`，同样需要 Bearer。接口返回结构与 HTTP 不完全相同。
3. 用户脚本：WebSocket 默认端口 `5558`，消息含 `auth_token` 和笔记数据/序号。现有服务验证来源为小红书/RedNote 网页；原生 iOS 客户端不能假定无 Origin 的连接已被允许。`accepted` 只表示入队，没有完整进度/完成协议；应先补协议再在手机显示“电脑下载完成”。
4. 令牌绑定电脑 `Volume/auth_secret.key`，不是小红书登录 Cookie。此处仅记录协议，不新增手机端连接设置或令牌存储。

依据：[app.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/application/app.py)、[script.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/module/script.py)、[auth.py](https://github.com/JoeanAmier/XHS-Downloader/blob/dfad51b3d1aac55866802007544f9390ad21553f/source/module/auth.py)。

## 已选范围的实施顺序与验收

执行范围以上方移动端决定为准，下列代码改动已在 build 25 完成。

| 顺序 | 工作 | 最小验收 |
| --- | --- | --- |
| 先修解析缺口 | URL 派生 fileKey、全编码键与备用地址、已知水印标记、保留 RedNote 会话域 | 用有/无 fileId、urlPre-only、未知编码键、备用地址-only、已知水印规格的少量解析样本检查真实策略调用；真机确认一个受影响链接 |
| 保存结果 | 现有照片/文件结果的清楚表达、失败补存、文件打开或分享 | 检查一次双目的地一半失败的结果与补存入口；不重复建立状态存储 |
| 多选便利 | 已有多选菜单复制所选链接 | 检查选择数量、内容去重，以及复制不触发自下载；不新增工具页 |

首次登录 Cookie 同步和标题转场已在 build 24 独立交付，build 25 不再修改该动画。接口对比属于代码与协议审核，没有运行真实账号批量抓取、远端 API/MCP 下载或电脑脚本端到端测试；表内“已覆盖”表示代码调用链存在，不代表本轮重新实测所有功能。
