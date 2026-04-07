import 'dart:convert';

class SyncVersionModel {
  final String deviceId;
  final String deviceName;
  final int lastUpdateTime; // 时间戳
  final int dbVersion;
  final int fileCount; // 数据库内记录总数，用于粗略校验

  SyncVersionModel({
    required this.deviceId,
    required this.deviceName,
    required this.lastUpdateTime,
    this.dbVersion = 1,
    this.fileCount = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'lastUpdateTime': lastUpdateTime,
      'dbVersion': dbVersion,
      'fileCount': fileCount,
    };
  }

  factory SyncVersionModel.fromJson(Map<String, dynamic> map) {
    return SyncVersionModel(
      deviceId: map['deviceId'] ?? '',
      deviceName: map['deviceName'] ?? 'Unknown Device',
      lastUpdateTime: map['lastUpdateTime'] ?? 0,
      dbVersion: map['dbVersion'] ?? 1,
      fileCount: map['fileCount'] ?? 0,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  static SyncVersionModel? fromJsonString(String jsonStr) {
    try {
      return SyncVersionModel.fromJson(jsonDecode(jsonStr));
    } catch (e) {
      return null;
    }
  }
}
