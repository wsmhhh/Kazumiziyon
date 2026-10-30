# Kazumi BT 下载与 RSS 订阅

这个分支给 Kazumi 增加了原生 BT 下载和 RSS 自动追番：

- **BT 下载页**：添加磁力 / `.torrent`，查看进度、速度、暂停/继续/删除，支持**边下边播**。
- **BT 弹幕**：播放器按种子文件名自动识别番剧名和集数，从 DanDanPlay 拉取弹幕；识别不准时可手动搜索番剧、修正集数。字号、透明度、显示区域、屏蔽规则沿用全局弹幕设置。
- **番剧页原播放器播放**：番剧详情页的播放来源会多出「BT 下载」源，点集数即可用原播放器播放（离线模式），弹幕按 bgm 番剧 ID 获取，历史记录也能续播。
- **RSS 订阅页**：内置 Mikan 蜜柑、DMHY 动漫花园、AniBT（`https://anibt.net/rss/magnets.xml`）预设，也支持任意 RSS/Atom 地址。
- **自动下载**：应用运行时按设定间隔刷新订阅，命中关键词的新条目自动加入 BT 下载。
- **边下边播**：aria2 使用 `stream-piece-selector=inorder` + `bt-prioritize-piece=head` 顺序下载，media_kit/mpv 直接播放仍在增长的视频文件。

## 架构

```
lib/services/bt/aria2_engine.dart        aria2c 进程管理（启动/停止/端口/密钥）
lib/services/bt/aria2_client.dart        JSON-RPC 客户端
lib/services/bt/bt_download_controller.dart  任务轮询 + UI 状态（ChangeNotifier）
lib/services/bt/bt_danmaku_controller.dart   BT 播放器弹幕（DanDanPlay 自动/手动匹配）
lib/services/bt/bt_playback_library.dart     把 BT 任务匹配到番剧并映射成离线剧集
lib/services/rss/rss_parser.dart         RSS 2.0 / Atom 解析
lib/services/rss/rss_controller.dart     订阅刷新 + 自动下载规则
lib/services/rss/rss_store.dart          订阅与"已处理"记录（Hive JSON）
lib/pages/bt/                            BT 页、播放器、RSS 页与设置页
```

RSS 订阅和去重记录保存在 Hive 的 `btRssSubscriptions` / `btRssSeen` 两个 box 中，都是 JSON 字符串，不需要额外的 Hive adapter。

## 依赖与构建

新增了一个 Dart 依赖（RSS 解析）：

```bash
flutter pub get
```

无需运行 `build_runner`。解析器有单元测试：

```bash
flutter test test/rss_parser_test.dart
```

### 桌面端（Windows / Linux / macOS）

安装 aria2 即可，引擎会自动在以下位置查找：

1. 设置里手动指定的路径（BT 设置 → aria2 可执行文件）
2. Kazumi 可执行文件同目录的 `aria2c.exe` / `aria2c`
3. 系统 PATH：`/usr/bin/aria2c`、`/usr/local/bin/aria2c`、`/opt/homebrew/bin/aria2c`

Windows 示例：`winget install aria2.aria2`，或把 `aria2c.exe` 放到 `kazumi.exe` 旁边。

### Android（内置引擎）

Google 从 Android 10 起禁止执行应用数据目录里的二进制文件，但允许执行
`nativeLibraryDir` 中的文件。因此需要把 **静态编译的 aria2c** 命名为
`libaria2c.so`，放到对应 ABI 目录：

```
android/app/src/main/jniLibs/arm64-v8a/libaria2c.so
android/app/src/main/jniLibs/armeabi-v7a/libaria2c.so
android/app/src/main/jniLibs/x86_64/libaria2c.so
```

最省事的获取方式：用项目里的脚本从 [abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build)
的每周 `continuous` 构建下载 musl 静态版（arm64 手机只需要一条命令）：

```bash
tool/fetch_aria2_android.sh            # arm64-v8a，大多数手机
tool/fetch_aria2_android.sh armeabi-v7a
tool/fetch_aria2_android.sh x86_64     # 模拟器
```

脚本会下载、解压并调用 `tool/package_aria2_android.sh` 放到正确的 jniLibs 目录。
如果你已有现成的静态 aria2c，也可以直接：

```bash
tool/package_aria2_android.sh /path/to/aria2c arm64-v8a
```

然后按 ABI 打包：

```bash
flutter build apk --split-per-abi
```

注意：

- 打 universal APK 时必须给 `armeabi-v7a`、`arm64-v8a`、`x86_64` 都放二进制，
  否则对应 ABI 的安装包没有引擎；`--split-per-abi` 可以只关心自己手机的 ABI。
- 静态 musl 版本不依赖 Android 的 bionic 动态库，直接可执行。
- Android 没有 `/etc/resolv.conf`，Kazumi 启动 aria2 时会自动加
  `--async-dns-server=223.5.5.5,1.1.1.1`，否则磁力里的 tracker 域名无法解析。
- `.torrent` 链接由应用自己用 Dio 下载（走系统证书），再以 base64 交给 aria2，
  所以 Android 版 aria2 不需要 CA 证书包；磁力链接则完全不经过 HTTPS。
- 引擎进程随应用运行，应用被系统杀掉后任务会暂停，重新打开应用即可继续。
- aria2 使用 GPLv2；如果分发内含 aria2c 的 APK，请同时提供对应源代码。

替代方案（可选）：`io.github.junkfood02.youtubedl-android:aria2c` 这个 Maven
依赖也打包了 Android 版 aria2，但它是压缩在 `.zip.so` 里、由该库自己解压的，
接入方式与这里的「nativeLibraryDir 里的独立可执行文件」不同，需要额外适配，
因此本项目默认走静态二进制方案。

仓库不附带二进制文件；缺少时 BT 引擎会提示"未找到内置 aria2 引擎"，并引导到
「BT 设置 → 内置引擎说明」，其它功能不受影响。

## 用 GitHub 打包安卓 APK（小白版）

**直接上传代码就打包，默认是没有 BT 引擎的**，因为仓库里不放 aria2 二进制。本仓库已经在构建流程里加了自动下载步骤，所以按下面做就能得到带 BT 的 APK：

1. 把整个项目（包括 `.github/workflows/`）推送到自己的 GitHub 仓库。
2. 打开仓库页面 → **Actions**。第一次会提示启用工作流，点启用。
3. 左侧选择 **Android BT APK** → 右侧 **Run workflow** → 选 `main` 分支 → **Run**。
4. 等 10–20 分钟。构建完成后点进这次运行，在页面底部 **Artifacts** 下载 `Kazumi-BT-arm64-apk`，解压得到 `app-arm64-v8a-release.apk`，传到手机安装。

这个 APK 已经内置 aria2（arm64 手机通用），BT 下载、边下边播、番剧页的「BT 下载」源都能直接用。

需要注意：

- 只构建了 **arm64**（绝大多数手机）。很老的 32 位手机需要在本机运行 `tool/fetch_aria2_android.sh armeabi-v7a` 后再打包。
- 弹幕依赖 DanDanPlay 的 `DANDANAPI_APPID` / `DANDANAPI_KEY`。没有配置这两个 Secrets 也能构建和用 BT，只是弹幕接口会认证失败；BT 下载、RSS 不受影响。
- 如果使用仓库原有的 `release` 流程（打 tag 触发），我也加上了同一步；但它还需要签名等 Secrets，自己用建议直接走 **Android BT APK**。
- 自己构建的 APK 是调试签名，和官方版签名不同，**不能覆盖安装官方版**，需要先卸载官方 Kazumi（会清掉应用内数据）。

如果不想用 GitHub，在 **WSL / Ubuntu** 里装好 Flutter 后执行（Windows 的 Git Bash 默认没有 unzip，容易失败）：

```bash
tool/fetch_aria2_android.sh arm64-v8a
flutter pub get
flutter build apk --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。

## 使用

1. 我的 → **BT 下载**：首次进入自动启动引擎；点「添加任务」粘贴磁力或选择 `.torrent`。
2. 任务卡片上「边下边播」直接打开播放器；已完成的任务显示「播放」。
3. **在番剧页用原播放器播放**：打开一部有 BT 下载的番剧详情页 → 播放来源（规则）→ 顶部会多出一个 **BT 下载** 来源，列出已下载/下载中的集数（未下完会标出进度）。点一集就用原来的播放器播放：弹幕、手势、倍速、选集、历史记录都在，走的是原播放器的离线模式。
4. 我的 → **RSS 订阅**：添加订阅，选择来源并填写关键词：
   - Mikan / DMHY：按关键词搜索订阅。
   - AniBT：订阅全站最新发布，用本地关键词筛选。
   - 自定义：粘贴任意 RSS/Atom 地址。
4. 打开订阅后可查看条目并手动下载；打开「自动下载新条目」后，只有**订阅之后发布**的新条目会自动入库（添加订阅时会把已有条目标记为已处理，避免一次拉取整部番）。
5. 「排除关键词」可过滤合集/字幕组，「起始集数」可跳过前面的集数。

BT 来源的匹配规则：番剧的中文名、原名、别名只要有一个出现在种子名或文件名中，就归到这部番；同一集有多个版本时保留下载进度更高的一个。历史记录会以「BT 下载」为来源保存，点击可以直接续播（依赖任务快照缓存，文件被删除后该记录会失效）。

## 已知限制

- aria2 进程随应用运行；应用被系统杀掉后任务会暂停，重新打开即可继续（文件已写入磁盘，不会丢失）。
- 不启用做种（`seed-time=0`），下载完成后停止上传。
- 边下边播：aria2 对 BT 没有完整的顺序下载能力，只能通过 `bt-prioritize-piece=head`
  优先下载文件头，所以从头播放通常可用，但拖动到尚未下载的位置会等待缓冲。对
  体验要求很高的场景，后续可以把引擎替换成支持纯顺序下载的客户端（qBittorrent
  的 Web API 等）。
- 删除任务只移除任务记录，已下载文件保留在下载目录中，需要手动清理。
- 弹幕按种子文件名自动匹配，命名不规范的种子可能识别失败或识别到错误的番剧/集数；播放器右上的放大镜按钮可以手动搜索番剧并改集数。弹幕来自 DanDanPlay，需要网络。
- 番剧页的 BT 来源按标题包含关系匹配，不同季或同名的番剧可能被混在一起（同集号会去重）；目前没有手动“关联到番剧”的入口，遇到混流可以先把无关任务删除。
- RSS 自动下载每次刷新最多触发 5 个任务，失败条目会在下一轮重试。

## 涉及的主要改动

- `pubspec.yaml`：新增 `xml`。
- `lib/pages/my/my_space_view.dart`、`my_page.dart`：新增「BT 下载」「RSS 订阅」入口。
- `lib/pages/info/source_sheet.dart`、`source_sheet_view.dart`：播放来源面板顶部新增「BT 下载」本地源。
- `lib/pages/video/video_controller.dart`：本地路径回退到路由传入的离线剧集，供 BT 使用。
- `lib/services/player/history_playback_service.dart`：历史记录恢复支持 BT 来源。
- `lib/pages/settings/settings_page.dart`：资源分组新增入口。
- `lib/pages/settings/settings_module.dart`：新增 `/settings/bt`、`/settings/rss`、`/settings/rss/feed`。
- `lib/pages/index_module.dart`、`lib/pages/bt/bt_module.dart`：新增 `/bt/`、`/bt/player`。
- `lib/services/storage/storage.dart`、`settings_keys.dart`：新增 box（含 `btTasks` 任务快照）与设置项。
- `android/.../MainActivity.kt`：新增 `com.predidit.kazumi/bt` 通道，提供 `nativeLibraryDir`。
- `android/app/build.gradle`：`jniLibs.useLegacyPackaging = true`。
