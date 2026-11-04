/// A single encrypted file tracked by the vault index.
///
/// The entry is only metadata: the encrypted container itself stays in the
/// user's folder (in-place). [uri] points at that container.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.relativePath,
    required this.addedAt,
  });

  final String id;
  final String uri;
  final String name;
  final String mime;
  final int size;
  final String relativePath;
  final int addedAt;

  VaultEntry copyWith({
    String? uri,
    String? name,
    String? mime,
    int? size,
    String? relativePath,
    int? addedAt,
  }) {
    return VaultEntry(
      id: id,
      uri: uri ?? this.uri,
      name: name ?? this.name,
      mime: mime ?? this.mime,
      size: size ?? this.size,
      relativePath: relativePath ?? this.relativePath,
      addedAt: addedAt ?? this.addedAt,
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
    };
  }

  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    return VaultEntry(
      id: json['id'] as String,
      uri: json['uri'] as String,
      name: json['name'] as String? ?? 'Unknown',
      mime: json['mime'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      relativePath: json['relativePath'] as String? ?? '',
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
