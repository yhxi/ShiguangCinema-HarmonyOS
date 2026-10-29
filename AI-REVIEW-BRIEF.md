# 时光影院 HarmonyOS v1.1.2 —— 优化审查简报

> 写给接下来接手审查的 AI（或人）。读完这份再动代码，能避开我们已经踩过的所有坑。
> 项目根目录：`E:/Development/shiguang harmonyos`
> 参考实现（Android 版，功能与视觉的对照基准）：`E:/Development/ShiguangCinema-v0.17-style-B`

---

## 1. 项目是什么

LibreTV 服务端的鸿蒙客户端：搜索 / 点播 / 直播 / 追剧 / 播放进度记忆。
对标同名 Android TV 应用（`yhxi/ShiguangCinema-Android-TV`），目标是功能与 UI 对齐。

- **技术栈**：ArkTS + AVPlayer + XComponent，单 module（entry），deviceTypes 仅 `phone`
- **版本**：versionName 1.1.2 / versionCode 10102（规则：`major*10000 + minor*100 + patch`）
- **权限**：仅 INTERNET / CAMERA（扫码）/ KEEP_BACKGROUND_RUNNING，没有多余权限
- **代码量**：~6800 行 ArkTS，最大单文件 `pages/Player.ets` 1395 行

## 2. 工作约定（动代码前必读）

1. **这个仓库是 public 的，任何凭据不得入库**。已经发生过一次服务端密码泄漏
   （`store/DefaultServer.ets` 曾硬编码），现在的约定：
   - 服务端密码**不随包分发**：用户首次手输，之后存系统凭据库（`store/Credentials.ets`，asset 服务）
   - 签名脚本密码从环境变量 `SIGN_PWD` 读；`sign/`（.p12/.csr）已被 `.gitignore` 排除
   - 提交前用 `git grep --cached` 查一遍历史密码字符串
2. **注意产物二进制也参与审查**：HAP 解包能提取字符串，源码干净不代表包干净。
   发布前建议解包 grep 一次。
3. **发布流程**（目前手动）：改 `AppScope/app.json5` 版本 → `sign-hap.cmd` 的 OUT 名同步 →
   构建 → 复制 HAP 到仓库根目录（命名 `ShiguangCinema-HarmonyOS-vX.Y.Z-unsigned.hap`）→
   commit + tag `vX.Y.Z` + push → 建 GitHub Release 并上传 HAP。
   本机无 gh CLI；git push 走 Windows 凭据管理器（用户 yhxi）静默认证，
   API 调用可用 `git credential fill` 取 token（**不要打印它**）。
4. **UI 以 Android 版为准**：布局/配色/图标几何都从 `MainActivity.kt` / `HomeIcons.kt`
   抄过来，颜色常量在 MainActivity.kt:214-221（ACCENT #0F766E 等）。
   鸿蒙侧集中在 `common/Theme.ets`（含首页选中格专用色 TILE_ACTIVE #34736E）。
5. **构建验证**：
   ```
   DEVECO_SDK_HOME=E:\Development\command-line-tools\sdk
   hvigorw.bat --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon assembleHap
   ```
   产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。
   `tests/*.cjs` 是 node 侧的逻辑复刻测试（play-urls / playback-settings / video-layout）。

## 3. 代码地图

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `pages/Player.ets` | 1395 | 播放页：AVPlayer+XComponent、手势、选集、后台播放、失败自愈、缓冲/网速提示 |
| `pages/Index.ets` | 683 | 首页：连接表单、品牌行、五入口、最近观看、豆瓣推荐流、更新胶囊与弹窗 |
| `api/Api.ets` | 596 | 服务端 API 封装（search/detail/douban/source test 等）+ Cookie 会话 |
| `pages/SourceManage.ets` | 516 | 片源管理：启停/测速（并发池）/订阅导入/直播源 |
| `store/Prefs.ets` | 490 | 全部持久化：服务端/Cookie/片源/历史/追剧/播放设置/推荐缓存/更新状态 |
| `pages/Detail.ets` | 304 | 详情：选集、续播、追剧 |
| `components/PosterImage.ets` | 247 | 海报组件：内存 LRU + 磁盘缓存 + 直连失败走代理 |
| `pages/Settings.ets` | 225 | 设置页：卡片 + 检查更新（应用内下载） |
| `pages/Live.ets` | 224 | 直播：M3U 分组 + 过滤 |
| `pages/NetDiag.ets` | 203 | 网络诊断：服务端/豆瓣/各片源并行探测 |
| `pages/Scan.ets` | 202 | 扫码（ScanKit）+ 手动粘贴兜底 |
| `pages/Search.ets` | 178 | 搜索：直连源并行 + 服务端聚合，失败回退 |
| `api/DirectCms.ets` | 162 | 采集站直连（绕过服务端） |
| `components/HomeIcon.ets` | 152 | 首页矢量图标（24×24 路径，移植 Android HomeIcons.kt） |
| `api/UpdateChecker.ets` | 134 | GitHub Releases 检查（tag 比较、错误分类） |
| `components/UpdateDialog.ets` | 120 | 更新弹窗：应用内下载进度条 + 打开 |
| `api/UpdateDownloader.ets` | ~80 | request.downloadFile 封装，进度回调 |
| `api/PlayUrls.ets` | — | 点播地址解析（原生线路优先） |
| `store/Session.ets` | — | 会话状态：serverUrl/api/sources/直连缓存 |
| `common/Theme.ets` | — | 颜色/圆角令牌（对齐 Android） |

## 4. 已知短板（我们知道但没做，按你判断优先级）

1. **崩溃日志**：设置页入口是占位（`Settings.showCrashInfo` 只弹 toast）。
   Android 版有 CrashLog.install() + 文件落盘 + 查看/复制。鸿蒙侧要用
   `errorManager.on('error')` 在 EntryAbility 挂钩 + 落盘 + 查看页。
2. **播放设置缺 4 项**（Android 有、鸿蒙无）：解码方式、缓存上限、起播缓冲、
   自动跳片头片尾。前三个 AVPlayer 没有对应 API（写死的 fixedRow）；
   跳片头片尾目前只有播放页每剧标注（`SkipMarks`），没有全局开关字段——加的话要动
   `PlaybackSettings` 接口 + 迁移旧数据。
3. **换源依赖实时搜索**：`Player.switchToNextSource` 每次失败都重新 `api.search`。
   Android 版用全局 `lastResults` 缓存，鸿蒙没有——首屏换源会多一次搜索延迟。
4. **检查更新只在 GitHub**：Android 走 Releases 下载 APK 直接安装；鸿蒙是下载到沙箱 +
   交给其他应用签名/安装（HAP 无法自装，这是平台限制不是功能缺失）。
5. **无 i18n**：全部中文硬编码。
6. **无 ETS 层单元测试**：tests/*.cjs 是把逻辑用 node 复刻一遍来测的，存在双份漂移风险。
7. **遥控器焦点体系未移植**：Android 的 D-pad 焦点描边/自动聚焦。deviceTypes 只有 phone
   所以目前不需要；上平板/电视才要。

## 5. 值得探索的优化方向（按主题，附现状证据）

### 5.1 播放历史还能再省
- `Prefs.saveWatch` 已改为内存缓存 + 直接序列化（v1.1.2），但**每 5 秒仍全量
  stringify 100 条 + flush 落盘一次**（`Player.startSaveTimer`，setInterval 5000）。
  可以做脏标记 + 30 秒合并落盘（退出播放页已有 `saveProgress(true)` 兜底）。
- `Prefs.getMap/putMap` 每次都全量解析/序列化整个 map（sources/cookies/
  recommendations 都走它）。调用量低，但 sources 列表大时（几百个源）连接时会卡一下。

### 5.2 海报缓存（v1.1.2 刚做了三层，仍有缝隙）
- **没有失败负缓存**：下载失败的 URL 不缓存失败结果，滚动列表时每个渲染周期都会重试。
  建议：失败记录 + 5 分钟 TTL。
- 磁盘层是 JPEG 重编码（packToData quality 82），首写有一次 CPU 开销；
  可以考虑直接存原始字节（但会丢 desiredSize 缩放收益）。
- 墓地延迟释放（120s）是工程折中，不是严格安全——极端情况下仍可能释放被引用的位图。
  如果真机出现海报花屏/崩溃，先查这里。

### 5.3 Player.ets 该拆了
1395 行单文件，职责至少 6 块：播放内核、手势、控制栏 UI、选集面板、后台播放/AVSession、
失败自愈 + 网速。拆分时注意：
- `bindPlayerEvents` 的 generation 模式（每次 setupPlayer 递增，旧回调全部作废）是
  防竞态的核心，拆分时不能丢。
- `triedSourceUrls` / `sameUrlRetried` / `sourceSwitchTried` 三个自愈标志的复位点
  在 startRenderFrame、selectEpisode、switchEpisode、retryPlayback 四处，别漏。

### 5.4 列表与渲染
- 首页推荐用 `GridRow` 一次渲染 24 张海报（`Index.homeView`），搜索结果/历史是普通
  `List` + `ForEach`。数据量小时没问题；如果以后加"全部加载/无限滚动"，
  换 `LazyForEach` + IDataSource。
- `Player` 的 `@State curMs` 随 `timeUpdate` 高频变化，会触发绑定它的 UI 局部刷新。
  进度条时间文本是主要消费者；如果发现掉帧，把高频值抽到独立子组件。

### 5.5 网络层
- 每个请求都 `http.createHttp()` 新建后销毁（Api/DirectCms/PosterImage/NetDiag 同模式）。
  行为正确，但无连接复用；量大的场景（海报并发 6 路）可以考虑会话级复用或
  换 `rcp`（Remote Communication Kit）。
- 搜索的直连并发**没有上限**（`Search.doSearch` 对所有启用源同时发起）；
  片源测速是并发池（`SourceManage.testAllSources`）。源很多时搜索建议也套池子。

### 5.6 发布流程自动化
版本号、sign-hap.cmd 的 OUT 名、README 里的版本引用、HAP 复制改名、Release 创建——
现在是五处手工同步，已经漏过一次（1.0.1 撞版本）。写个 release 脚本（PowerShell 或 node）
一次做完 + 校验，能消掉一类事故。

## 6. ArkTS / 鸿蒙踩坑实录（我们交过学费的）

1. **`Path.commands` 用 px 坐标系**，而组件 width/height 是 vp。按 vp 算路径坐标，
   图标只会渲染 1/密度 大小并贴左上角（v1.0.1 翻过车）。
   修法：`commands(path(kind, size * vp2px(1)))`，宽高仍用 vp。
2. **自定义组件的 `@Prop` 不能叫 `size` / `color`**，与内置属性冲突
   （`10505001 Property 'size' ... not assignable`）。用 `iconSize` / `tint`。
3. **Kit 导出名不直觉**：`@kit.CoreFileKit` 里 fs 叫 `fileIo`；`fs.listFile` 只有异步版，
   同步是 `listFileSync`；`image.createImagePacker()` 而非 `new image.Packer()`。
4. **禁止内联对象字面量类型**（arkts-no-obj-literals-as-types）：`Array<{a,b}>` 不行，
   要声明 interface；`{ format, quality }` 这类选项字面量要对应显式 interface。
5. **PixelMap 生命周期**：release 掉画面上还引用的位图会花屏/崩溃。缓存逐出用延迟释放
   （宽限期方案见 PosterImage），不要见洞就堵。
6. **setInterval/clearInterval 在 ArkTS 可用**（项目早期只敢用 setTimeout）。
7. **router / pushUrl 在部分 SDK 版本报 deprecated 警告**，构建仍通过；暂不迁移。

## 7. 真机待验证清单（下次有设备时按这个过）

| 项 | 位置 | 预期 |
| --- | --- | --- |
| 海报磁盘缓存 | 刷首页 → 杀进程 → 重开 | 封面秒出、不走网络；全灰则查 `filesDir/poster-cache/` |
| 更新下载 302 | 设置→检查更新→下载 | 进度条走动；卡 0% 说明 request.downloadFile 没跟随 GitHub 重定向 |
| 下载文件授权 | 下载完成→打开 | 能唤起其他应用；不行就改用 DocumentViewPicker 存到用户目录 |
| HLS 网速显示 | 播放卡顿源 | 缓冲中 + KB/s；数字不出现说明 CACHED_DURATION 没上报，需退化为百分比×码率 |
| 播放失败自愈 | 手动填一个坏源 | 重试→自动换源→提示，链条不循环 |
| 缓冲/暂停提示 | 暂停、拖动后缓冲 | 居中「已暂停」/「缓冲中」+网速，无大播放钮叠加 |

## 8. 历史教训（防止重演）

- **v1.0.1 图标 1/3 大小事故**：构建成功 ≠ 渲染正确；自绘预览（PIL 按自己的参数重画）
  等于自己验证自己。UI 改动必须真机截图核对。
- **服务端密码泄漏**：密码曾硬编码在源码里推上公开仓库。已从源码、历史、HAP 二进制
  三层清除（`git log -p --all` 0 处 + 解包 grep）。**旧密码已在公网暴露过，服务端密码
  仍应轮换**；被强推掉的旧提交 c50a396 在 GitHub 上仍可按 SHA 访问（dangling commit），
  彻底清除需 GitHub Support。
- **v1.0.1 Release 已删除**（坏包），tag 保留。

---

*生成于 2026-10-29，对应提交 6f9b179。*
