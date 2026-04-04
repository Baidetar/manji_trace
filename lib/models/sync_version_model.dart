/// 备份版本追踪模型 - 用于管理备份版本历史和增量备份信息
class SyncVersion {
  final String id;                    // 唯一标识符（使用时间戳+随机数）
  final int versionNumber;            // 版本号（递增）
  final DateTime createTime;          // 创建时间
  final String backupMode;            // 备份模式: 'full'(完整), 'incremental'(增量)
  final String source;                // 来源: 'manual'(手动), 'automatic'(自动), 'sync'(同步)
  final String device;                // 设备标识
  
  // 元数据统计
  final int recordCount;              // 记录数量
  final int labelCount;               // 标签数量
  final int noteImageCount;           // 笔记图片数量
  final int coverImageCount;          // 封面图片数量
  final int totalSize;                // 备份文件大小(字节)
  
  // 增量备份信息
  final String? parentVersionId;      // 父版本ID(用于增量链)
  final int? addedRecords;            // 新增记录数
  final int? modifiedRecords;         // 修改的记录数
  final int? deletedRecords;          // 删除的记录数
  final List<String>? changedImageIds; // 变更的图片ID列表
  
  // 备份位置
  final String? localPath;            // 本地备份路径
  final String? remotePath;           // 远程备份路径(WebDav)
  final String? md5Checksum;          // MD5校验和

  const SyncVersion({
    required this.id,
    required this.versionNumber,
    required this.createTime,
    required this.backupMode,
    required this.source,
    required this.device,
    required this.recordCount,
    required this.labelCount,
    required this.noteImageCount,
    required this.coverImageCount,
    required this.totalSize,
    this.parentVersionId,
    this.addedRecords,
    this.modifiedRecords,
    this.deletedRecords,
    this.changedImageIds,
    this.localPath,
    this.remotePath,
    this.md5Checksum,
  });

  /// 转换为Map(用于JSON序列化)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'versionNumber': versionNumber,
      'createTime': createTime.toIso8601String(),
      'backupMode': backupMode,
      'source': source,
      'device': device,
      'recordCount': recordCount,
      'labelCount': labelCount,
      'noteImageCount': noteImageCount,
      'coverImageCount': coverImageCount,
      'totalSize': totalSize,
      'parentVersionId': parentVersionId,
      'addedRecords': addedRecords,
      'modifiedRecords': modifiedRecords,
      'deletedRecords': deletedRecords,
      'changedImageIds': changedImageIds?.join(',') ?? '',
      'localPath': localPath,
      'remotePath': remotePath,
      'md5Checksum': md5Checksum,
    };
  }

  /// 从Map创建对象
  factory SyncVersion.fromMap(Map<String, dynamic> map) {
    return SyncVersion(
      id: map['id'] as String,
      versionNumber: map['versionNumber'] as int,
      createTime: DateTime.parse(map['createTime'] as String),
      backupMode: map['backupMode'] as String,
      source: map['source'] as String,
      device: map['device'] as String,
      recordCount: map['recordCount'] as int,
      labelCount: map['labelCount'] as int,
      noteImageCount: map['noteImageCount'] as int,
      coverImageCount: map['coverImageCount'] as int,
      totalSize: map['totalSize'] as int,
      parentVersionId: map['parentVersionId'] as String?,
      addedRecords: map['addedRecords'] as int?,
      modifiedRecords: map['modifiedRecords'] as int?,
      deletedRecords: map['deletedRecords'] as int?,
      changedImageIds: (map['changedImageIds'] as String?)?.isNotEmpty ?? false
          ? (map['changedImageIds'] as String).split(',')
          : null,
      localPath: map['localPath'] as String?,
      remotePath: map['remotePath'] as String?,
      md5Checksum: map['md5Checksum'] as String?,
    );
  }

  /// 复制对象，用于修改部分字段
  SyncVersion copyWith({
    String? id,
    int? versionNumber,
    DateTime? createTime,
    String? backupMode,
    String? source,
    String? device,
    int? recordCount,
    int? labelCount,
    int? noteImageCount,
    int? coverImageCount,
    int? totalSize,
    String? parentVersionId,
    int? addedRecords,
    int? modifiedRecords,
    int? deletedRecords,
    List<String>? changedImageIds,
    String? localPath,
    String? remotePath,
    String? md5Checksum,
  }) {
    return SyncVersion(
      id: id ?? this.id,
      versionNumber: versionNumber ?? this.versionNumber,
      createTime: createTime ?? this.createTime,
      backupMode: backupMode ?? this.backupMode,
      source: source ?? this.source,
      device: device ?? this.device,
      recordCount: recordCount ?? this.recordCount,
      labelCount: labelCount ?? this.labelCount,
      noteImageCount: noteImageCount ?? this.noteImageCount,
      coverImageCount: coverImageCount ?? this.coverImageCount,
      totalSize: totalSize ?? this.totalSize,
      parentVersionId: parentVersionId ?? this.parentVersionId,
      addedRecords: addedRecords ?? this.addedRecords,
      modifiedRecords: modifiedRecords ?? this.modifiedRecords,
      deletedRecords: deletedRecords ?? this.deletedRecords,
      changedImageIds: changedImageIds ?? this.changedImageIds,
      localPath: localPath ?? this.localPath,
      remotePath: remotePath ?? this.remotePath,
      md5Checksum: md5Checksum ?? this.md5Checksum,
    );
  }

  @override
  String toString() {
    return 'SyncVersion(id: $id, version: $versionNumber, '
        'records: $recordCount, images: $noteImageCount/$coverImageCount, '
        'time: ${createTime.toString()})';
  }

  /// 获取版本摘要文字（用于UI展示）
  String getSummary() {
    StringBuffer summary = StringBuffer();
    summary.write('版本 #$versionNumber · ');
    summary.write('${createTime.hour.toString().padLeft(2, '0')}:'
        '${createTime.minute.toString().padLeft(2, '0')} · ');
    
    if (backupMode == 'incremental' && parentVersionId != null) {
      summary.write('增量备份');
      if (addedRecords != null && addedRecords! > 0) {
        summary.write(' (+$addedRecords)');
      }
      if (modifiedRecords != null && modifiedRecords! > 0) {
        summary.write(' (编辑$modifiedRecords)');
      }
      if (deletedRecords != null && deletedRecords! > 0) {
        summary.write(' (-$deletedRecords)');
      }
    } else {
      summary.write('完整备份 · $recordCount条记录');
    }
    
    if (changedImageIds != null && changedImageIds!.isNotEmpty) {
      summary.write(' · 图片×${changedImageIds!.length}');
    }
    
    return summary.toString();
  }
}
