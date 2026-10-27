/// Merge one native settings edit without losing unrelated preferences.
Map<String, dynamic> mergeNativeSettings(
  Map<String, dynamic> current,
  Map<String, dynamic> patch,
) {
  final result = Map<String, dynamic>.from(current);
  for (final entry in patch.entries) {
    final previous = result[entry.key];
    result[entry.key] = previous is Map && entry.value is Map
        ? mergeNativeSettings(
            Map<String, dynamic>.from(previous),
            Map<String, dynamic>.from(entry.value as Map),
          )
        : entry.value;
  }
  return result;
}
