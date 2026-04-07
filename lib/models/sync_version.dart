import 'dart:convert';

class SyncVersion {
  final String id;
  final int versionNumber;
  final DateTime createTime;
  final String backupMode; // 'full', 'incremental'
  final String source;     // 'manual', 'automatic', 'sync'
  final String device;
  final int recordCount;
  final int labelCount;
  final int noteImageCount;
  final int coverImageCount;
  final int totalSize;
  final String? parentVersionId;
  final int? addedRecords;
  final int? modifiedRecords;
  final int? deletedRecords;
  final String? changedImageIds; // JSON string of list
  final String? localPath;
  final String? remotePath;
  final String? md5Checksum;
  final DateTime? createdAt;

  SyncVersion({
    required this.id,
    required this.versionNumber,
    required this.createTime,
    required this.backupMode,
    required this.source,
    required this.device,
    this.recordCount = 0,
    this.labelCount = 0,
    this.noteImageCount = 0,
    this.coverImageCount = 0,
    this.totalSize = 0,
    this.parentVersionId,
    this.addedRecords,
    this.modifiedRecords,
    this.deletedRecords,
    this.changedImageIds,
    this.localPath,
    this.remotePath,
    this.md5Checksum,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'version_number': versionNumber,
      'create_time': createTime.toIso8601String(),
      'backup_mode': backupMode,
      'source': source,
      'device': device,
      'record_count': recordCount,
      'label_count': labelCount,
      'note_image_count': noteImageCount,
      'cover_image_count': coverImageCount,
      'total_size': totalSize,
      'parent_version_id': parentVersionId,
      'added_records': addedRecords,
      'modified_records': modifiedRecords,
      'deleted_records': deletedRecords,
      'changed_image_ids': changedImageIds,
      'local_path': localPath,
      'remote_path': remotePath,
      'md5_checksum': md5Checksum,
    };
  }

  factory SyncVersion.fromMap(Map<String, dynamic> map) {
    return SyncVersion(
      id: map['id'],
      versionNumber: map['version_number'],
      createTime: DateTime.parse(map['create_time']),
      backupMode: map['backup_mode'],
      source: map['source'],
      device: map['device'],
      recordCount: map['record_count'] ?? 0,
      labelCount: map['label_count'] ?? 0,
      noteImageCount: map['note_image_count'] ?? 0,
      coverImageCount: map['cover_image_count'] ?? 0,
      totalSize: map['total_size'] ?? 0,
      parentVersionId: map['parent_version_id'],
      addedRecords: map['added_records'],
      modifiedRecords: map['modified_records'],
      deletedRecords: map['deleted_records'],
      changedImageIds: map['changed_image_ids'],
      localPath: map['local_path'],
      remotePath: map['remote_path'],
      md5Checksum: map['md5_checksum'],
      createdAt: map['created_at'] != null ? DateTime.parse(map['created_at']) : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory SyncVersion.fromJson(String source) => SyncVersion.fromMap(json.decode(source));
}
