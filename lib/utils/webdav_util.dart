import 'dart:convert';
import 'dart:typed_data';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/utils/error_format_util.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:manji_trace/utils/log.dart';

class WebDavUtil {
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

  static Future<String> getRemoteDirPath() async {
    if (RemoteController.to.isOffline) {
      ToastUtil.showText("请先连接帐号，再进行备份");
      return "";
    }
    String backupDir = "/animetrace";
    // readDir('/')遍历判断是否存在animetrace目录，不如直接创建，如果存在则会跳过
    await client.mkdir(backupDir);
    return backupDir;
  }

  static Future<String> getRemoteAutoDirPath(String backupDir) async {
    String autoDir = "$backupDir/automatic";
    // TeraCloud直接执行readDir时，如果目录不存在并不会自动创建，因此会抛出异常DioError [DioErrorType.response]: Not Found
    await WebDavUtil.client.mkdir(autoDir);
    return autoDir;
  }
}
