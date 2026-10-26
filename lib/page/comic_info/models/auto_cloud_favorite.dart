import 'dart:convert';

/// 只认登录成功后保存的会话，不把已填写的账号、密码当成登录成功。
/// 无法识别登录状态的插件保守跳过，避免后台操作触发登录。
bool hasPluginLoginSession(Map<String, dynamic> config) {
  for (final key in [
    'auth.token',
    'auth.authorization',
    'auth.cookie',
    'auth.cookies',
  ]) {
    final value = _decodeConfigValue(config[key]);
    if (value is String && value.trim().isNotEmpty) return true;
    if ((key == 'auth.cookie' || key == 'auth.cookies') &&
        value is Map &&
        value.values.any((item) => item is String && item.trim().isNotEmpty)) {
      return true;
    }
  }

  // 禁漫将登录响应保存为 auth.userInfo，退出登录时清空。
  final user = _decodeConfigValue(config['auth.userInfo']);
  return user is Map &&
      ['uid', 'id', 'jwttoken'].any((key) {
        final value = user[key];
        return value != null &&
            value.toString().trim().isNotEmpty &&
            value.toString() != '0';
      });
}

dynamic _decodeConfigValue(dynamic value) {
  if (value is! String || value.trim().isEmpty) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

/// 返回 null 表示跳过。云端失败向调用方报告，不回滚本地收藏。
Future<bool?> autoCollectToCloud({
  required bool enabled,
  required bool pluginReady,
  required bool supportsCloudFavorite,
  required bool currentStatus,
  required Map<String, dynamic> loginConfig,
  required Future<bool> Function() addFavorite,
}) async {
  if (!enabled ||
      !pluginReady ||
      !supportsCloudFavorite ||
      currentStatus ||
      !hasPluginLoginSession(loginConfig)) {
    return null;
  }
  return addFavorite();
}
