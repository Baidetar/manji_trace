# 漫迹 (Manji Trace) - 项目上下文指南

欢迎来到 **漫迹 (Manji Trace)** 项目。这是一个使用 Flutter 开发的跨平台动漫清单管理软件，支持 Android、iOS 和 Windows。它旨在帮助用户记录观看历史、笔记、评分，并提供动漫搜索及 WebDAV 备份功能。

## 项目概览

- **核心技术栈**: Flutter (Dart), GetX (状态管理), SQFlite (本地数据库), Dio (网络请求).
- **架构模式**: 采用 Controller-Service-DAO 模式。
    - **Controllers**: 处理 UI 逻辑与状态 (`lib/controllers`).
    - **DAO (Data Access Objects)**: 封装数据库操作 (`lib/dao`).
    - **Models**: 定义数据结构 (`lib/models`).
    - **Utils**: 通用工具类，如数据库初始化 (`SqliteUtil`)、网络配置 (`DioUtil`)、WebDAV 支持等.
- **数据存储**: 使用 SQLite 进行本地存储。数据库初始化与表结构管理位于 `lib/utils/sqlite_util.dart`。

## 开发规范与约定

### 1. 状态管理 (GetX)
项目深度集成 `GetX`。
- 使用 `Get.lazyPut` 或 `Get.put` 初始化 Controller。
- 习惯性在 Controller/Service 中定义 `static SettingService get to => Get.find();` 方便快捷访问。
- 页面通常分为 `view.dart` 和 `controller.dart`。

### 2. 数据库与持久化
- **DAO 模式**: 所有的数据库表操作必须封装在 `lib/dao` 下的对应 DAO 类中。
- **字段命名**: 数据库字段通常使用下划线命名法（如 `anime_id`），而在 Dart Model 中对应驼峰命名法（如 `animeId`）。
- **KeyValue 存储**: 简单的配置项使用 `SPUtil` (SharedPreferences) 或 `KeyValueDao` (基于 SQLite) 存储。

### 3. 时间格式
- `createTime` 和 `updateTime` 在模型中通常存储为 `String`，格式为 `yyyy-MM-dd HH:mm:ss`。

### 4. 平台适配
- 项目针对 Windows 和 Android 有大量适配逻辑，见 `Global.init()` 和各处 `Platform.isWindows` 判断。
- 桌面端窗口管理使用 `window_manager`。

## 构建与运行

### 环境准备
- Flutter SDK (见 `pubspec.yaml` 中的版本要求)
- 运行 `flutter pub get` 安装依赖。

### 常用命令
- **运行调试**: `flutter run`
- **构建 Windows 版**: `flutter build windows`
- **构建 Android 版**: `flutter build apk`
- **清理缓存**: `flutter clean`

## 重要文件索引
- `lib/main.dart`: 应用入口，初始化全局配置。
- `lib/global.dart`: 全局静态配置与初始化逻辑。
- `lib/utils/sqlite_util.dart`: 数据库表结构定义。
- `lib/utils/webdav_util.dart`: WebDAV 备份核心逻辑。
- `lib/dao/`: 所有的数据库操作接口。

## 注意事项
- **图片路径**: 笔记中的图片存储的是相对路径。
- **备份安全**: 提醒用户使用 WebDAV 进行云端备份以防数据丢失。
- **Windows 构建**: 若遇到原生资源（native assets）构建失败，尝试 `flutter clean` 并检查 Visual Studio 编译环境。
