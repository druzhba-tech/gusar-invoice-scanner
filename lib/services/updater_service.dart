import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final DateTime? publishedAt;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    this.publishedAt,
  });
}

class UpdaterService {
  static final UpdaterService _instance = UpdaterService._internal();
  factory UpdaterService() => _instance;
  UpdaterService._internal();

  static const String repoOwner = 'druzhba-tech';
  static const String repoName = 'gusar-invoice-scanner';

  UpdateInfo? lastDetectedUpdate;

  // 1. Проверка наличия обновлений на GitHub Releases
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final currentInfo = await PackageInfo.fromPlatform();
      final currentVersion = currentInfo.version;

      final url = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest');
      final response = await http.get(url, headers: {
        'User-Agent': 'Gusar-Scanner-App',
        'Accept': 'application/vnd.github.v3+json',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tag = data['tag_name']?.toString().replaceAll('v', '').replaceAll('V', '') ?? '1.0.0';
        final body = data['body']?.toString() ?? 'Доступно плановое обновление приложения Gusar Scanner.';
        final publishedStr = data['published_at']?.toString();
        DateTime? publishedAt;
        if (publishedStr != null) {
          publishedAt = DateTime.tryParse(publishedStr);
        }

        // Поиск скомпилированного APK файла в активах релиза
        final assets = data['assets'] as List<dynamic>? ?? [];
        String? apkUrl;
        for (var asset in assets) {
          final name = asset['name']?.toString() ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = asset['browser_download_url'];
            break;
          }
        }

        // Если APK нет в релизе напрямую, сформируем прямую ссылку на репозиторий
        apkUrl ??= 'https://github.com/$repoOwner/$repoName/releases/latest';

        if (_isNewer(tag, currentVersion)) {
          lastDetectedUpdate = UpdateInfo(
            version: tag,
            downloadUrl: apkUrl,
            releaseNotes: body,
            publishedAt: publishedAt,
          );
          return lastDetectedUpdate;
        }
      }
    } catch (e) {
      debugPrint('Update check warning: $e');
    }
    return null;
  }

  // 2. Точное сравнение версий (SemVer: major.minor.patch)
  bool _isNewer(String remote, String current) {
    try {
      final rClean = remote.split('-').first.replaceAll(RegExp(r'[^0-9.]'), '');
      final cClean = current.split('-').first.replaceAll(RegExp(r'[^0-9.]'), '');
      
      final rParts = rClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final cParts = cClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      final maxLen = rParts.length > cParts.length ? rParts.length : cParts.length;
      for (int i = 0; i < maxLen; i++) {
        final r = i < rParts.length ? rParts[i] : 0;
        final c = i < cParts.length ? cParts[i] : 0;
        if (r > c) return true;
        if (r < c) return false;
      }
      return false;
    } catch (_) {
      return remote.trim() != current.trim();
    }
  }

  // 3. Проверка: отложил ли пользователь уведомление для конкретной версии
  Future<bool> isUpdatePostponed(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final postponedVersion = prefs.getString('postponed_update_version');
    final postponedTime = prefs.getInt('postponed_update_time') ?? 0;

    if (postponedVersion == version) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Если прошло меньше 12 часов с момента выбора «Позже», не открывать навязчивое окно
      if (now - postponedTime < 12 * 60 * 60 * 1000) {
        return true;
      }
    }
    return false;
  }

  // 4. Запомнить выбор пользователя «Позже / Я сам решу»
  Future<void> postponeUpdate(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('postponed_update_version', version);
    await prefs.setInt('postponed_update_time', DateTime.now().millisecondsSinceEpoch);
  }

  // 5. Сбросить отложенный статус (когда пользователь нажал обновиться)
  Future<void> clearPostponedUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('postponed_update_version');
    await prefs.remove('postponed_update_time');
  }

  // 6. Запуск скачивания APK
  Future<void> launchDownload(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
