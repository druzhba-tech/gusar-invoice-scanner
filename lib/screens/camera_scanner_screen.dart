import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../models/invoice_document.dart';
import '../services/ocr_service.dart';
import '../services/matching_service.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import 'invoice_review_screen.dart';

class CameraScannerScreen extends StatefulWidget {
  final List<String>? preselectedImages;
  final bool autoLaunchNativeCamera;

  const CameraScannerScreen({
    super.key,
    this.preselectedImages,
    this.autoLaunchNativeCamera = false,
  });

  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen> {
  final List<String> _capturedPages = [];
  bool _isProcessing = false;
  String _processingStatus = 'Анализ документа...';

  final OcrService _ocr = OcrService();
  final MatchingService _matcher = MatchingService();
  final ApiService _api = ApiService();
  final LocalStorageService _storage = LocalStorageService();
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    if (widget.preselectedImages != null && widget.preselectedImages!.isNotEmpty) {
      _capturedPages.addAll(widget.preselectedImages!);
    }
    _matcher.init();

    if (widget.autoLaunchNativeCamera && _capturedPages.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _takePhotoWithNativeCamera();
      });
    }
  }

  // 1. Съёмка штатной системной камерой телефона
  Future<void> _takePhotoWithNativeCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 100, // Максимальное качество для точного OCR
      );

      if (photo != null && mounted) {
        setState(() {
          _capturedPages.add(photo.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось запустить камеру телефона: $e. Попробуйте выбрать фото из галереи.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // 2. Выбор нескольких фото из галереи телефона
  Future<void> _pickFromGallery() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(imageQuality: 100);
      if (images.isNotEmpty && mounted) {
        setState(() {
          _capturedPages.addAll(images.map((e) => e.path));
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка выбора из галереи: $e')),
        );
      }
    }
  }

  // 3. Выбор PDF или графического файла через проводник телефона
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty && mounted) {
        final validPaths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
        setState(() {
          _capturedPages.addAll(validPaths);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка открытия файлов: $e')),
        );
      }
    }
  }

  // 4. Запуск распознавания накладной и таблиц
  Future<void> _processInvoice() async {
    if (_capturedPages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сфотографируйте или выберите хотя бы один лист накладной!')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _processingStatus = 'Нейросеть читает накладную (OCR + Vision AI)...';
    });

    try {
      // 1. Распознавание накладной / чека
      final doc = await _ocr.parseInvoiceWithVisionAi(_capturedPages);

      if (doc == null || doc.items.isEmpty) {
        setState(() => _isProcessing = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Не удалось разобрать позиции. Убедитесь, что текст четкий, или сфотографируйте ближе.'),
              backgroundColor: Colors.orangeAccent,
            ),
          );
        }
        return;
      }

      setState(() => _processingStatus = 'Сопоставление товаров с базой gusar.tj...');

      // 2. Получение каталога и умное сопоставление
      try {
        final catalog = await _api.getProducts();
        _matcher.autoMatchDocument(doc, catalog);
      } catch (_) {}

      // 3. Сохранение черновика локально
      await _storage.saveInvoice(doc);

      setState(() => _isProcessing = false);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => InvoiceReviewScreen(document: doc)),
        );
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка обработки: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text('Приёмка и сканирование', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          if (_capturedPages.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() => _capturedPages.clear()),
              icon: const Icon(Icons.clear_all_rounded, color: Colors.white54, size: 18),
              label: const Text('Очистить', style: TextStyle(color: Colors.white54, fontSize: 13)),
            ),
        ],
      ),
      body: Stack(
        children: [
          _capturedPages.isEmpty ? _buildEmptyState() : _buildPagesList(),

          // Индикатор AI распознавания
          if (_isProcessing)
            Container(
              color: Colors.black.withOpacity(0.85),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Color(0xFF10B981)),
                      const SizedBox(height: 20),
                      Text(
                        _processingStatus,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Извлекаем наименования, цены, суммы и артикулы...',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _capturedPages.isNotEmpty ? _buildBottomActionBar() : null,
    );
  }

  // Экран выбора способа добавления (когда страниц еще нет)
  Widget _buildEmptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF10B981).withOpacity(0.15),
                  const Color(0xFF0284C7).withOpacity(0.15),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.document_scanner_rounded, color: Color(0xFF10B981), size: 32),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Оцифровка накладной / чека',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Используется штатная камера телефона с максимальной чёткостью и вспышкой',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'ВЫБЕРИТЕ СПОСОБ СЪЁМКИ:',
            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1),
          ),
          const SizedBox(height: 12),

          // Карточка 1: Штатная камера телефона (Главная рекомендация)
          _optionTile(
            icon: Icons.camera_alt_rounded,
            color: const Color(0xFF10B981),
            title: 'Сфотографировать камерой телефона',
            subtitle: 'Открывает стандартную камеру смартфона (автофокус, вспышка, максимальное качество)',
            badge: 'Рекомендуется',
            onTap: _takePhotoWithNativeCamera,
          ),

          const SizedBox(height: 12),

          // Карточка 2: Галерея смартфона
          _optionTile(
            icon: Icons.photo_library_rounded,
            color: const Color(0xFF0284C7),
            title: 'Выбрать фото из Галереи',
            subtitle: 'Можно выбрать один или несколько готовых снимков накладной',
            onTap: _pickFromGallery,
          ),

          const SizedBox(height: 12),

          // Карточка 3: Файл или PDF
          _optionTile(
            icon: Icons.picture_as_pdf_rounded,
            color: const Color(0xFF8B5CF6),
            title: 'Выбрать PDF / Файл документа',
            subtitle: 'Если накладная получена через WhatsApp, Telegram или почту',
            onTap: _pickFile,
          ),

          const SizedBox(height: 30),

          // Подсказка для качественного распознавания
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                Icon(Icons.lightbulb_outline_rounded, color: Colors.amber, size: 22),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Совет: держите камеру ровно над документом при хорошем освещении, чтобы все строки таблицы и суммы были разборчивы.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Список уже добавленных страниц (когда есть хотя бы 1 фото)
  Widget _buildPagesList() {
    return Column(
      children: [
        // Информационная полоса сверху
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1E293B),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Добавлено листов: ${_capturedPages.length}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_a_photo_rounded, color: Color(0xFF10B981), size: 22),
                    tooltip: 'Снять ещё лист камерой',
                    onPressed: _takePhotoWithNativeCamera,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate_rounded, color: Color(0xFF0284C7), size: 22),
                    tooltip: 'Добавить из галереи',
                    onPressed: _pickFromGallery,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Сетка предпросмотра страниц
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _capturedPages.length + 1,
            itemBuilder: (context, index) {
              if (index == _capturedPages.length) {
                // Кнопка добавления следующего листа
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.add_a_photo_rounded, color: Color(0xFF10B981)),
                    label: const Text('+ Снять следующий лист (камерой телефона)', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                    onPressed: _takePhotoWithNativeCamera,
                  ),
                );
              }

              final path = _capturedPages[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    // Миниатюра страницы
                    ClipRRect(
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                      child: Container(
                        width: 90,
                        height: 100,
                        color: Colors.black45,
                        child: path.toLowerCase().endsWith('.pdf')
                            ? const Icon(Icons.picture_as_pdf, color: Colors.redAccent, size: 36)
                            : Image.file(
                                File(path),
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white30),
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Описание листа
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Лист #${index + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 4),
                          Text(
                            path.split(Platform.pathSeparator).last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                          const SizedBox(height: 6),
                          const Text('Готов к распознаванию', style: TextStyle(color: Color(0xFF10B981), fontSize: 11)),
                        ],
                      ),
                    ),
                    // Кнопка удаления листа
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                      tooltip: 'Удалить лист',
                      onPressed: () {
                        setState(() {
                          _capturedPages.removeAt(index);
                        });
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Нижняя панель действий (кнопка распознать)
  Widget _buildBottomActionBar() {
    return Container(
      color: const Color(0xFF1E293B),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.bolt_rounded, size: 22),
                label: Text(
                  'Распознать документ (${_capturedPages.length} стр.)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                onPressed: _processInvoice,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    String? badge,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white30),
          ],
        ),
      ),
    );
  }
}
