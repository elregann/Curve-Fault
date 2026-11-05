/// Where a vault entry came from.
enum VaultSource {
  /// The user locked this file from their own storage.
  self,

  /// The file was received from another CurveVault identity.
  received,
}

/// A single encrypted file tracked by the vault index.
///
/// The entry is only metadata: the encrypted container itself stays in the
/// user's folder (in-place) or, for received files, in app-private storage.
/// [uri] points at that container.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.relativePath,
    required this.addedAt,
    this.source = VaultSource.self,
    this.senderPublicKey,
    this.receivedAt,
    this.contentHash,
  });

  final String id;
  final String uri;
  final String name;
  final String mime;
  final int size;
  final String relativePath;
  final int addedAt;
  final VaultSource source;

  /// Hex-encoded Curve256189 public key of the sender, for received files.
  final String? senderPublicKey;

  /// When the file finished transferring, for received files.
  final int? receivedAt;

  /// Hex-encoded SHA-256 of the encrypted container, for received files.
  final String? contentHash;

  bool get isReceived => source == VaultSource.received;

  VaultEntry copyWith({
    String? uri,
    String? name,
    String? mime,
    int? size,
    String? relativePath,
    int? addedAt,
    VaultSource? source,
    String? senderPublicKey,
    int? receivedAt,
    String? contentHash,
  }) {
    return VaultEntry(
      id: id,
      uri: uri ?? this.uri,
      name: name ?? this.name,
      mime: mime ?? this.mime,
      size: size ?? this.size,
      relativePath: relativePath ?? this.relativePath,
      addedAt: addedAt ?? this.addedAt,
      source: source ?? this.source,
      senderPublicKey: senderPublicKey ?? this.senderPublicKey,
      receivedAt: receivedAt ?? this.receivedAt,
      contentHash: contentHash ?? this.contentHash,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'uri': uri,
      'name': name,
      'mime': mime,
      'size': size,
      'relativePath': relativePath,
      'addedAt': addedAt,
      'source': source.name,
      if (senderPublicKey != null) 'senderPublicKey': senderPublicKey,
      if (receivedAt != null) 'receivedAt': receivedAt,
      if (contentHash != null) 'contentHash': contentHash,
    };
  }

  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    final rawSource = json['source'] as String?;
    return VaultEntry(
      id: json['id'] as String,
      uri: json['uri'] as String,
      name: json['name'] as String? ?? 'Unknown',
      mime: json['mime'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      relativePath: json['relativePath'] as String? ?? '',
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
      source: rawSource == VaultSource.received.name
          ? VaultSource.received
          : VaultSource.self,
      senderPublicKey: json['senderPublicKey'] as String?,
      receivedAt: (json['receivedAt'] as num?)?.toInt(),
      contentHash: json['contentHash'] as String?,
    );
  }
}
