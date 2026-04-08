import 'dart:convert';
import 'dart:typed_data';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/utils/error_format_util.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:manji_trace/utils/log.dart';

class WebDavUtil {
  static const String preferredRemoteDir = "/漫记";
  static const String backupSubDirName = "backup";
  static const String syncSubDirName = "sync";
  static const List<String> legacyRemoteDirs = ["/manji_trace", "/animetrace"];

  static WebDavUtil? _webDavUtil;

  WebDavUtil._();

  static WebDavUtil getInstance() {
    return _webDavUtil ??= WebDavUtil._();
  }

  static late Client client;

  static Future<bool> initWebDav(
      String uri, String user, String password) async {
    client = newClient(
      uri,
      user: user,
      password: password,
      debug: false,
    );
    if (!(await pingWebDav())) {
      AppLog.info("WebDav初始化失败！");
      return false;
    }
    // Set the public request headers
    client.setHeaders({'accept-charset': 'utf-8'});

    // 读取用户设置的超时时间，默认30秒
    int timeout = SPUtil.getInt("webdav_timeout", defaultValue: 30000);

    // Set the connection server timeout time in milliseconds.
    client.setConnectTimeout(timeout);

    // Set send data timeout time in milliseconds.
    client.setSendTimeout(timeout);

    // Set transfer data time in milliseconds.
    client.setReceiveTimeout(timeout);

    AppLog.info("WebDav初始化成功！超时时间：${timeout}ms");
    return true;
  }

  static Future<bool> pingWebDav() async {
    try {
      await client.ping();
    } catch (e) {
      // 不应该设置为false，应该假设login为true，这样每次进入应用都会init重新连接
      // SPUtil.setBool("login", false); // 如果之前成功，但现在失败了，所以需要覆盖
      // 应该用online=true表示在线还是
      RemoteController.to.setOnline(false);
      ErrorFormatUtil.formatError(e);
      return false;
    }
    RemoteController.to.setOnline(true);
    SPUtil.setBool("login", true); // 表示用户想要登录，第一次登录后永远为true
    AppLog.info("ping ok");
    return true;
  }

  static Future<void> upload(String localPath, String remotePath) async {
    return client.writeFromFile(
      localPath,
      remotePath,
    );
  }

  static Future<void> uploadString(String content, String remotePath) async {
    return client.write(remotePath, Uint8List.fromList(utf8.encode(content)));
  }

  static Future<String?> readString(String remotePath) async {
    try {
      var data = await client.read(remotePath);
      return utf8.decode(data);
    } catch (e) {
      // 文件可能不存在，不抛出异常
      return null;
    }
  }

  static Future<String> getRemoteBackupDirPath() async {
    if (RemoteController.to.isOffline) {
      ToastUtil.showText("请先连接帐号，再进行备份");
      return "";
    }
    await client.mkdir(preferredRemoteDir);
    const String backupDir = "$preferredRemoteDir/$backupSubDirName";
    await client.mkdir(backupDir);
    return backupDir;
  }

  static Future<String> getRemoteSyncDirPath() async {
    if (RemoteController.to.isOffline) {
      ToastUtil.showText("请先连接帐号，再进行同步");
      return "";
    }
    await client.mkdir(preferredRemoteDir);
    const String syncDir = "$preferredRemoteDir/$syncSubDirName";
    await client.mkdir(syncDir);
    return syncDir;
  }

  // 兼容旧调用：默认返回备份目录。
  static Future<String> getRemoteDirPath() async {
    return getRemoteBackupDirPath();
  }

  /// 获取用于读取备份/同步数据的目录列表（包含兼容旧目录）
  static Future<List<String>> getRemoteDirPathsForRead() async {
    if (RemoteController.to.isOffline) {
      return [];
    }

    final List<String> candidates = [preferredRemoteDir, ...legacyRemoteDirs];
    final List<String> existing = [];
    for (final dir in candidates) {
      if (await _remoteDirExists(dir)) {
        existing.add(dir);
      }
    }

    if (existing.isEmpty) {
      // 首次使用时创建新目录
      await client.mkdir(preferredRemoteDir);
      return [preferredRemoteDir];
    }

    // 读取时优先新目录
    if (!existing.contains(preferredRemoteDir)) {
      existing.insert(0, preferredRemoteDir);
    }
    return existing;
  }

  static Future<List<String>> getRemoteBackupDirPathsForRead() async {
    final List<String> bases = await getRemoteDirPathsForRead();
    final List<String> dirs = [];
    final Set<String> dedup = {};
    for (final base in bases) {
      final String backupDir = "$base/$backupSubDirName";
      if (await _remoteDirExists(backupDir) && dedup.add(backupDir)) {
        dirs.add(backupDir);
      }
      // 兼容旧版直接写在根目录
      if (dedup.add(base)) {
        dirs.add(base);
      }
    }
    return dirs;
  }

  static Future<List<String>> getRemoteSyncDirPathsForRead() async {
    final List<String> bases = await getRemoteDirPathsForRead();
    final List<String> dirs = [];
    final Set<String> dedup = {};
    for (final base in bases) {
      final String syncDir = "$base/$syncSubDirName";
      if (await _remoteDirExists(syncDir) && dedup.add(syncDir)) {
        dirs.add(syncDir);
      }
      // 兼容旧版直接写在根目录
      if (dedup.add(base)) {
        dirs.add(base);
      }
    }
    return dirs;
  }

  static Future<bool> _remoteDirExists(String remoteDir) async {
    try {
      await client.readDir(remoteDir);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> getRemoteAutoDirPath(String backupDir) async {
    String autoDir = "$backupDir/automatic";
    // TeraCloud直接执行readDir时，如果目录不存在并不会自动创建，因此会抛出异常DioError [DioErrorType.response]: Not Found
    await WebDavUtil.client.mkdir(autoDir);
    return autoDir;
  }
}
