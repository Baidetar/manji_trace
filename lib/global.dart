import 'dart:io';

import 'package:manji_trace/controllers/anime_service.dart';
import 'package:manji_trace/controllers/setting_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manji_trace/controllers/anime_display_controller.dart';
import 'package:manji_trace/controllers/app_upgrade_controller.dart';
import 'package:manji_trace/controllers/backup_service.dart';
import 'package:manji_trace/controllers/labels_controller.dart';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/controllers/update_record_controller.dart';
import 'package:manji_trace/pages/anime_collection/checklist_controller.dart';
import 'package:manji_trace/controllers/sync_service.dart';
import 'package:manji_trace/utils/dio_util.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/utils/platform.dart';
import 'package:manji_trace/utils/sp_profile.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:get/get.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'values/values.dart';

class Global {
  // 私有构造器，避免外部错误使用(也就是创建Global对象)
  Global._();

  static late String deviceId;
  static late String deviceName;

  /// 是否 release
  static bool get isRelease => const bool.fromEnvironment("dart.vm.product");

  /// 设备预览
  static bool get enableDevicePreview => false;

  /// 修改了笔记图片根路径
  static bool modifiedImgRootPath = false;

  /// 展开/收缩目录过滤器
  static bool expandDirectoryFilter = true;

  static Future<void> init() async {
    // 透明状态栏
    if (PlatformUtil.isMobile) {
      SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
    }
    // 确保初始化，否则会提示Unhandled Exception: Null check operator used on a null value
    WidgetsFlutterBinding.ensureInitialized();
    // MediaKit.ensureInitialized();
    // 获取SharedPreferences
    await SPUtil.getInstance();
    
    // 初始化设备信息
    await _initDeviceInfo();

    // 初始化图片私有目录
    await ImageUtil.initializePrivateDirs();
    // 桌面应用的sqflite初始化
    sqfliteFfiInit();
    // 网络
    DioUtil.init();
    // 确保数据库表最新结构
    await SqliteUtil.ensureDBTable();
    // put常用的getController
    await _putGetController();
    // 设置Windows窗口
    _handleWindowsManager();
    // 解决访问部分网络图片时报错CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate
    HttpOverrides.global = MyHttpOverrides();
    // 热键
    if (Platform.isWindows) await hotKeyManager.unregisterAll();
  }

  static Future<void> _initDeviceInfo() async {
    deviceId = SPUtil.getString("sync_device_id");
    if (deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      SPUtil.setString("sync_device_id", deviceId);
    }

    deviceName = SPUtil.getString("sync_device_name");
    if (deviceName.isEmpty) {
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceName = androidInfo.model;
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceName = iosInfo.name;
      } else if (Platform.isWindows) {
        WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
        deviceName = windowsInfo.computerName;
      } else if (Platform.isMacOS) {
        MacOsDeviceInfo macInfo = await deviceInfo.macOsInfo;
        deviceName = macInfo.computerName;
      } else {
        deviceName = "Unknown Device";
      }
      SPUtil.setString("sync_device_name", deviceName);
    }
  }

  static _putGetController() async {
    Get.lazyPut(() => BackupService());
    Get.lazyPut(() => SyncService());
    Get.lazyPut(() => AnimeService());
    Get.lazyPut(() => SettingService());

    Get.lazyPut(
        () => UpdateRecordController()); // 放在ensureDBTable后，因为init中访问到了表
    Get.lazyPut(() => AnimeDisplayController());
    Get.lazyPut(() => LabelsController());
    Get.lazyPut(() => RemoteController());
    Get.put(AppUpgradeController());

    final checklistController = ChecklistController();
    Get.put(checklistController);
    await checklistController.init();
  }

  static void _handleWindowsManager() async {
    // 只在Windows系统下开启窗口设置，否则Android端会白屏
    if (Platform.isWindows) {
      // Windows端窗口设置
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = WindowOptions(
        title: "漫迹",
        size: Size(SpProfile.getWindowWidth(), SpProfile.getWindowHeight()),
        // 最小尺寸
        // minimumSize: const Size(900, 600),
        minimumSize: const Size(400, 400),
        fullScreen: false,
        // 需要居中，否则会偏右
        center: !kDebugMode,
        // 透明会导致新版Win11的标题栏看不到最小化、最大化和关闭按钮
        // backgroundColor: Colors.transparent,
        skipTaskbar: false,
        // 隐藏标题栏
        // titleBarStyle: TitleBarStyle.hidden,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }
  }

  static exitApp() {
    if (PlatformUtil.isDesktop) {
      exit(0);
    } else {
      SystemNavigator.pop();
    }
  }

  /// 获取用于访问豆瓣图片的header，避免403
  static Map<String, String> getHeadersToGetDoubanPic() {
    return {
      "Referer": "douban.com",
      "User-Agent": bingUserAgent,
    };
  }

  /// 切换横竖屏
  static Future<void> switchDeviceOrientation(BuildContext context) async {
    return isPortrait(context) ? toLandscape() : toPortrait();
  }

  /// 切换为横屏
  static Future<void> toLandscape() {
    return SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeLeft,
    ]);
  }

  /// 切换为竖屏
  static Future<void> toPortrait() {
    return SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp]);
  }

  /// 恢复设备方向和系统任务栏
  static Future<void> restoreDevice() async {
    if (PlatformUtil.isMobile) {
      await Global.autoRotate();
      await Global.restoreSystemUIOverlays();
    }
  }

  /// 恢复为手机旋转时自动切换横竖屏。避免退出视频页后无法切换为横屏
  static Future<void> autoRotate() {
    return SystemChrome.setPreferredOrientations([]);
  }

  /// 是否为横屏
  static bool isLandscape(BuildContext context) {
    return MediaQuery.of(context).orientation == Orientation.landscape;
  }

  /// 是否为竖屏
  static bool isPortrait(BuildContext context) {
    return MediaQuery.of(context).orientation == Orientation.portrait;
  }

  /// 获取AppBar高度
  static getAppBarHeight(BuildContext context) {
    return kToolbarHeight + MediaQuery.of(context).padding.top;
  }

  /// 恢复系统顶部栏和底部栏，用于退出全屏
  static Future<void> restoreSystemUIOverlays() async {
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
  }

  /// 隐藏系统顶部栏和底部栏，用于进入全屏
  static Future<void> hideSystemUIOverlays() async {
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: []);
  }

  /// 是否为夜间模式
  static bool isDark(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark;
  }
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

class FeatureFlag {
  static final enableSelectLocalImage =
      Platform.isWindows || Platform.isAndroid;

  static const enableFixCover = false;
}
