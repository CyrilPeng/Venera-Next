enum BangumiProgressMode { auto, episode, volume }

enum BangumiProgressField { episode, volume }

enum BangumiTitleParseFailure {
  unknownUnit,
  ambiguous,
  decimal,
  negative,
  noNumber,
}

class BangumiProgress {
  final BangumiProgressField field;
  final int value;

  const BangumiProgress(this.field, this.value);

  String get apiField =>
      field == BangumiProgressField.episode ? 'ep_status' : 'vol_status';

  @override
  bool operator ==(Object other) =>
      other is BangumiProgress && other.field == field && other.value == value;

  @override
  int get hashCode => Object.hash(field, value);
}

class BangumiTitleParseResult {
  final BangumiProgress? progress;
  final BangumiTitleParseFailure? failure;

  const BangumiTitleParseResult.success(this.progress) : failure = null;

  const BangumiTitleParseResult.failure(this.failure) : progress = null;

  bool get isSuccess => progress != null;

  @override
  bool operator ==(Object other) =>
      other is BangumiTitleParseResult &&
      other.progress == progress &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(progress, failure);
}

class BangumiTitleProgressParser {
  static BangumiTitleParseResult parse(
    String source,
    BangumiProgressMode mode,
  ) {
    final title = source.replaceAllMapped(
      RegExp(r'[０-９]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
    );
    if (RegExp(r'\d+\.\d+').hasMatch(title)) {
      return const BangumiTitleParseResult.failure(
        BangumiTitleParseFailure.decimal,
      );
    }
    if (RegExp(r'-\s*\d+').hasMatch(title)) {
      return const BangumiTitleParseResult.failure(
        BangumiTitleParseFailure.negative,
      );
    }

    final field = switch (mode) {
      BangumiProgressMode.episode => BangumiProgressField.episode,
      BangumiProgressMode.volume => BangumiProgressField.volume,
      BangumiProgressMode.auto => _autoField(title),
    };
    if (field == null) {
      final hasEpisode = RegExp(r'[话話]').hasMatch(title);
      final hasVolume = RegExp(r'卷').hasMatch(title);
      return BangumiTitleParseResult.failure(
        hasEpisode && hasVolume
            ? BangumiTitleParseFailure.ambiguous
            : BangumiTitleParseFailure.unknownUnit,
      );
    }

    final values = _associatedValues(title, field).toSet();
    if (values.length == 1) {
      return BangumiTitleParseResult.success(
        BangumiProgress(field, values.single),
      );
    }
    if (values.length > 1) {
      return const BangumiTitleParseResult.failure(
        BangumiTitleParseFailure.ambiguous,
      );
    }

    final numbers = RegExp(
      r'\d+',
    ).allMatches(title).map((match) => match.group(0)!);
    final uniqueNumbers = numbers.map(int.parse).toSet();
    if (uniqueNumbers.isEmpty) {
      return const BangumiTitleParseResult.failure(
        BangumiTitleParseFailure.noNumber,
      );
    }
    if (uniqueNumbers.length > 1) {
      return const BangumiTitleParseResult.failure(
        BangumiTitleParseFailure.ambiguous,
      );
    }
    return BangumiTitleParseResult.success(
      BangumiProgress(field, uniqueNumbers.single),
    );
  }

  static BangumiProgressField? _autoField(String title) {
    final hasEpisode = RegExp(r'[话話]').hasMatch(title);
    final hasVolume = RegExp(r'卷').hasMatch(title);
    if (hasEpisode == hasVolume) {
      return null;
    }
    return hasEpisode
        ? BangumiProgressField.episode
        : BangumiProgressField.volume;
  }

  static Iterable<int> _associatedValues(
    String title,
    BangumiProgressField field,
  ) sync* {
    final unit = field == BangumiProgressField.episode ? r'[话話]' : r'卷';
    for (final pattern in [RegExp('\\d+\\s*$unit'), RegExp('$unit\\s*\\d+')]) {
      for (final match in pattern.allMatches(title)) {
        final value = RegExp(r'\d+').firstMatch(match.group(0)!)!.group(0)!;
        yield int.parse(value);
      }
    }
  }
}

class BangumiUser {
  final String username;
  final String nickname;

  const BangumiUser(this.username, this.nickname);

  factory BangumiUser.fromJson(Map<String, dynamic> json) => BangumiUser(
    json['username'] as String? ?? '',
    json['nickname'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'username': username, 'nickname': nickname};

  @override
  bool operator ==(Object other) =>
      other is BangumiUser &&
      other.username == username &&
      other.nickname == nickname;

  @override
  int get hashCode => Object.hash(username, nickname);
}

class BangumiSubject {
  final int id;
  final String title;
  final String originalTitle;
  final String coverUrl;
  final int totalEpisodes;
  final int totalVolumes;
  final String? platform;

  const BangumiSubject({
    required this.id,
    required this.title,
    required this.originalTitle,
    required this.coverUrl,
    required this.totalEpisodes,
    required this.totalVolumes,
    this.platform,
  });

  factory BangumiSubject.fromJson(Map<String, dynamic> json) {
    final originalTitle =
        (json['name'] ?? json['originalTitle']) as String? ?? '';
    final chineseTitle = (json['name_cn'] ?? json['title']) as String? ?? '';
    final images = json['images'];
    final apiCoverUrl = images is Map ? images['common'] as String? : null;
    return BangumiSubject(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: chineseTitle.isNotEmpty ? chineseTitle : originalTitle,
      originalTitle: originalTitle,
      coverUrl: apiCoverUrl ?? json['coverUrl'] as String? ?? '',
      totalEpisodes:
          ((json['eps'] ?? json['totalEpisodes']) as num?)?.toInt() ?? 0,
      totalVolumes:
          ((json['volumes'] ?? json['totalVolumes']) as num?)?.toInt() ?? 0,
      platform: json['platform'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'originalTitle': originalTitle,
    'coverUrl': coverUrl,
    'totalEpisodes': totalEpisodes,
    'totalVolumes': totalVolumes,
    'platform': platform,
  };
}

class BangumiCollection {
  final int type;
  final int rate;
  final int epStatus;
  final int volStatus;

  const BangumiCollection({
    required this.type,
    required this.rate,
    required this.epStatus,
    required this.volStatus,
  });

  factory BangumiCollection.fromJson(Map<String, dynamic> json) =>
      BangumiCollection(
        type: (json['type'] as num?)?.toInt() ?? 0,
        rate: (json['rate'] as num?)?.toInt() ?? 0,
        epStatus:
            ((json['ep_status'] ?? json['epStatus']) as num?)?.toInt() ?? 0,
        volStatus:
            ((json['vol_status'] ?? json['volStatus']) as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'type': type,
    'rate': rate,
    'epStatus': epStatus,
    'volStatus': volStatus,
  };
}

class BangumiBinding {
  final String sourceKey;
  final String comicId;
  final int subjectId;
  final String subjectTitle;
  final String subjectOriginalTitle;
  final String coverUrl;
  final BangumiProgressMode progressMode;
  final int totalEpisodes;
  final int totalVolumes;
  final int lastRemoteEpisode;
  final int lastRemoteVolume;
  final int rating;

  const BangumiBinding({
    required this.sourceKey,
    required this.comicId,
    required this.subjectId,
    required this.subjectTitle,
    required this.subjectOriginalTitle,
    required this.coverUrl,
    required this.progressMode,
    required this.totalEpisodes,
    required this.totalVolumes,
    required this.lastRemoteEpisode,
    required this.lastRemoteVolume,
    required this.rating,
  });

  factory BangumiBinding.fromJson(Map<String, dynamic> json) => BangumiBinding(
    sourceKey: json['sourceKey'] as String? ?? '',
    comicId: json['comicId'] as String? ?? '',
    subjectId: (json['subjectId'] as num?)?.toInt() ?? 0,
    subjectTitle: json['subjectTitle'] as String? ?? '',
    subjectOriginalTitle: json['subjectOriginalTitle'] as String? ?? '',
    coverUrl: json['coverUrl'] as String? ?? '',
    progressMode: _progressModeFromJson(json['progressMode']),
    totalEpisodes: (json['totalEpisodes'] as num?)?.toInt() ?? 0,
    totalVolumes: (json['totalVolumes'] as num?)?.toInt() ?? 0,
    lastRemoteEpisode: (json['lastRemoteEpisode'] as num?)?.toInt() ?? 0,
    lastRemoteVolume: (json['lastRemoteVolume'] as num?)?.toInt() ?? 0,
    rating: (json['rating'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'comicId': comicId,
    'subjectId': subjectId,
    'subjectTitle': subjectTitle,
    'subjectOriginalTitle': subjectOriginalTitle,
    'coverUrl': coverUrl,
    'progressMode': progressMode.name,
    'totalEpisodes': totalEpisodes,
    'totalVolumes': totalVolumes,
    'lastRemoteEpisode': lastRemoteEpisode,
    'lastRemoteVolume': lastRemoteVolume,
    'rating': rating,
  };

  BangumiBinding copyWith({
    String? sourceKey,
    String? comicId,
    int? subjectId,
    String? subjectTitle,
    String? subjectOriginalTitle,
    String? coverUrl,
    BangumiProgressMode? progressMode,
    int? totalEpisodes,
    int? totalVolumes,
    int? lastRemoteEpisode,
    int? lastRemoteVolume,
    int? rating,
  }) => BangumiBinding(
    sourceKey: sourceKey ?? this.sourceKey,
    comicId: comicId ?? this.comicId,
    subjectId: subjectId ?? this.subjectId,
    subjectTitle: subjectTitle ?? this.subjectTitle,
    subjectOriginalTitle: subjectOriginalTitle ?? this.subjectOriginalTitle,
    coverUrl: coverUrl ?? this.coverUrl,
    progressMode: progressMode ?? this.progressMode,
    totalEpisodes: totalEpisodes ?? this.totalEpisodes,
    totalVolumes: totalVolumes ?? this.totalVolumes,
    lastRemoteEpisode: lastRemoteEpisode ?? this.lastRemoteEpisode,
    lastRemoteVolume: lastRemoteVolume ?? this.lastRemoteVolume,
    rating: rating ?? this.rating,
  );

  @override
  bool operator ==(Object other) =>
      other is BangumiBinding &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.subjectId == subjectId &&
      other.subjectTitle == subjectTitle &&
      other.subjectOriginalTitle == subjectOriginalTitle &&
      other.coverUrl == coverUrl &&
      other.progressMode == progressMode &&
      other.totalEpisodes == totalEpisodes &&
      other.totalVolumes == totalVolumes &&
      other.lastRemoteEpisode == lastRemoteEpisode &&
      other.lastRemoteVolume == lastRemoteVolume &&
      other.rating == rating;

  @override
  int get hashCode => Object.hashAll([
    sourceKey,
    comicId,
    subjectId,
    subjectTitle,
    subjectOriginalTitle,
    coverUrl,
    progressMode,
    totalEpisodes,
    totalVolumes,
    lastRemoteEpisode,
    lastRemoteVolume,
    rating,
  ]);
}

String bangumiBindingKey(String sourceKey, String comicId) =>
    '${Uri.encodeComponent(sourceKey)}@${Uri.encodeComponent(comicId)}';

BangumiProgressMode _progressModeFromJson(Object? value) {
  if (value is String) {
    for (final mode in BangumiProgressMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
  }
  return BangumiProgressMode.auto;
}
