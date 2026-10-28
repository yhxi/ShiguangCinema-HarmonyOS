# 时光影院 · HarmonyOS

时光影院（ShiguangCinema）的鸿蒙版本，界面与功能对齐 Android 版
[yhxi/ShiguangCinema-Android-TV](https://github.com/yhxi/ShiguangCinema-Android-TV)。

连接 LibreTV 服务端后即可搜索、点播、看直播，本地保存观看历史与追剧列表。

## 安装包

仓库根目录的 `ShiguangCinema-HarmonyOS-v1.0.2-unsigned.hap` 是**未签名**构建，
需要自行签名后才能装到设备上（见下方「签名」）。

- bundleName：`com.lshai.shiguangcinema`
- versionName：`1.0.2` / versionCode：`10002`
- deviceTypes：`phone`

## 功能

- 首页：五个入口（点播 / 直播 / 搜索 / 追剧 / 设置，图标为矢量路径绘制）、
  最近观看、最新热门推荐（支持「混合 / 最新 / 热门 / 高分」榜单切换）
- 搜索：服务端聚合 + 直连采集源并行，失败自动回退
- 详情：选集、续播、追剧
- 播放：横屏、进度条、上下集、选集、倍速、清晰度、画面比例；
  点击画面中心暂停/继续，左右滑动调亮度/音量，水平滑动快进快退
- 直播：M3U 订阅，按分组折叠 + 关键词过滤
- 片源管理：点播源启停/测速/订阅导入，直播源切换
- 设置：片源管理、播放设置、切换服务端、清理缓存、网络诊断
- 后台播放：开启后播放中申请音频持续任务并创建 AVSession

## 构建

需要 DevEco Studio 或 command-line-tools（含 HarmonyOS SDK）。

```powershell
$env:DEVECO_SDK_HOME='E:\Development\command-line-tools\sdk'
& 'E:\Development\command-line-tools\bin\hvigorw.bat' `
--mode module `
-p module=entry@default `
-p product=default `
-p buildMode=debug `
--no-daemon assembleHap
```

产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`

也可以直接跑 `build-hap.cmd`（Windows）。

## 签名

仓库不含任何证书或密钥库。`sign-hap.cmd` 会从环境变量读取密码：

```cmd
set SIGN_PWD=你的密钥库密码
sign-hap.cmd
```

需要先把以下三个文件放进 `sign\`（`.gitignore` 已排除该目录）：

| 文件 | 说明 |
| --- | --- |
| `shiguang-debug.p12` | 密钥库 |
| `shiguang-debug.cer` | AGC 调试证书 |
| `shiguang-debug.p7b` | AGC 调试 profile |

## 与 Android 版的差异

- 焦点体系：Android 版面向遥控器（D-pad 焦点描边、自动聚焦），鸿蒙包目前只声明
  `phone`，触摸交互不需要焦点态，因此没有移植这一层。
- 检查更新：Android 版走 GitHub Releases 下载 APK 并安装；鸿蒙这边尚未接入
  分发源，且未签名 HAP 无法直接安装。
- 崩溃日志：目前只有入口，未落地应用内记录。
- 播放设置少 4 项：解码方式、缓存上限、起播缓冲、自动跳片头片尾——
  AVPlayer 没有对应 API，片头片尾也还没有全局开关字段。
- 「换源」与「只看可用源」：依赖 Android 版的全局搜索结果缓存，鸿蒙侧尚未实现。
