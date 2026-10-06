import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
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
  String? downloadedApkPath;

  // Получить текущую установленную версию приложения
  Future<String> getCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '1.0.4';
    }
  }

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

        final assets = data['assets'] as List<dynamic>? ?? [];
        String? apkUrl;
        for (var asset in assets) {
          final name = asset['name']?.toString() ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = asset['browser_download_url'];
            break;
          }
        }

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

  // 2. Сравнение версий
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

  // 3. Скачивание APK с отображением прогресса
  Future<String?> downloadApk({
    required String downloadUrl,
    required String version,
    required Function(double progress, int receivedBytes, int totalBytes) onProgress,
  }) async {
    try {
      final dio = Dio();
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/Gusar-Scanner-v$version.apk';

      // Если файл уже скачан полностью
      final existingFile = File(filePath);
      if (await existingFile.exists() && await existingFile.length() > 50 * 1024 * 1024) {
        final len = await existingFile.length();
        onProgress(1.0, len, len);
        downloadedApkPath = filePath;
        return filePath;
      }

      await dio.download(
        downloadUrl,
        filePath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress(received / total, received, total);
          }
        },
      );

      downloadedApkPath = filePath;
      return filePath;
    } catch (e) {
      debugPrint('Download APK error: $e');
      return null;
    }
  }

  // 4. Запуск установки скачанного APK
  Future<bool> installApk(String filePath) async {
    try {
      const channel = MethodChannel('tj.gusar.invoice_scanner/app_installer');
      final result = await channel.invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? false;
    } catch (e) {
      debugPrint('Install APK error: $e');
      // В случае ошибки пробуем запустить через стандартный браузер
      final uri = Uri.parse('https://github.com/$repoOwner/$repoName/releases/latest');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    }
  }

  // 5. Диалог с живым индикатором загрузки и кнопкой установки
  void showDownloadAndInstallDialog(BuildContext context, UpdateInfo update) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => _DownloadProgressDialog(
        update: update,
        updater: this,
      ),
    );
  }

  Future<bool> isUpdatePostponed(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final postponedVersion = prefs.getString('postponed_update_version');
    final postponedTime = prefs.getInt('postponed_update_time') ?? 0;

    if (postponedVersion == version) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - postponedTime < 12 * 60 * 60 * 1000) {
        return true;
      }
    }
    return false;
  }

  Future<void> postponeUpdate(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('postponed_update_version', version);
    await prefs.setInt('postponed_update_time', DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clearPostponedUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('postponed_update_version');
    await prefs.remove('postponed_update_time');
  }

  Future<void> launchDownload(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

// -------------------------------------------------------------
// Интерактивный диалог скачивания и установки обновления
// -------------------------------------------------------------
class _DownloadProgressDialog extends StatefulWidget {
  final UpdateInfo update;
  final UpdaterService updater;

  const _DownloadProgressDialog({required this.update, required this.updater});

  @override
  State<_DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _isDownloading = true;
  bool _isDone = false;
  String? _error;
  String? _apkPath;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  void _startDownload() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _error = null;
    });

    final path = await widget.updater.downloadApk(
      downloadUrl: widget.update.downloadUrl,
      version: widget.update.version,
      onProgress: (prog, received, total) {
        if (mounted) {
          setState(() {
            _progress = prog;
            _receivedBytes = received;
            _totalBytes = total;
          });
        }
      },
    );

    if (mounted) {
      if (path != null) {
        setState(() {
          _isDownloading = false;
          _isDone = true;
          _apkPath = path;
        });
      } else {
        setState(() {
          _isDownloading = false;
          _error = 'Не удалось загрузить файл. Проверьте интернет-соединение.';
        });
      }
    }
  }

  void _install() {
    if (_apkPath != null) {
      widget.updater.installApk(_apkPath!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final percentInt = (_progress * 100).clamp(0, 100).toInt();
    final receivedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = _totalBytes > 0 ? (_totalBytes / (1024 * 1024)).toStringAsFixed(1) : '58.8';

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isDone ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF38BDF8).withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isDone ? Icons.check_circle_rounded : Icons.download_rounded,
              color: _isDone ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isDone ? 'Обновление скачано!' : 'Скачивание обновления',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text('Версия v${widget.update.version}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isDownloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 10,
                backgroundColor: Colors.white10,
                color: const Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$percentInt%', style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 14)),
                Text('$receivedMb МБ из $totalMb МБ', style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Пожалуйста, подождите. Файл скачивается напрямую в память телефона...',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ] else if (_isDone) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.verified, color: Color(0xFF10B981), size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Файл готов к установке', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                        SizedBox(height: 2),
                        Text('Нажмите кнопку ниже, чтобы обновить приложение без потери данных.', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
              label: const Text('Повторить скачивание', style: TextStyle(color: Color(0xFF38BDF8))),
              onPressed: _startDownload,
            ),
          ],
        ],
      ),
      actions: [
        if (!_isDownloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть', style: TextStyle(color: Colors.white54)),
          ),
        if (_isDone)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.system_update_rounded, color: Colors.white),
            label: const Text('УСТАНОВИТЬ СЕЙЧАС', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(context);
              _install();
            },
          ),
      ],
    );
  }
}

