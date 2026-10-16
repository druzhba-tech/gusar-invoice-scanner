import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../models/invoice_document.dart';
import '../services/ocr_service.dart';
import '../services/matching_service.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../utils/image_utils.dart';
import '../utils/top_notification.dart';
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

  // 1. Съёмка штатной системной камерой телефона с аппаратной 2K-оптимизацией
  Future<void> _takePhotoWithNativeCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90, // Оптимальный баланс: 600-800 КБ, без потери резкости букв и цифр
      );

      if (photo != null && mounted) {
        setState(() {
          _capturedPages.add(photo.path);
        });
      }
    } catch (e) {
      if (mounted) {
        TopNotification.showError(context, 'Не удалось запустить камеру телефона: $e. Попробуйте выбрать фото из галереи.');
      }
    }
  }

  // 2. Выбор нескольких фото из галереи телефона
  Future<void> _pickFromGallery() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
      if (images.isNotEmpty && mounted) {
        setState(() {
          _capturedPages.addAll(images.map((e) => e.path));
        });
      }
    } catch (e) {
      if (mounted) {
        TopNotification.showError(context, 'Ошибка выбора из галереи: $e');
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
        TopNotification.showError(context, 'Ошибка открытия файлов: $e');
      }
    }
  }

  // 4. Запуск распознавания накладной и таблиц
  Future<void> _processInvoice() async {
    if (_capturedPages.isEmpty) {
      TopNotification.showWarning(context, 'Сфотографируйте или выберите хотя бы один лист накладной!');
      return;
    }

    setState(() {
      _isProcessing = true;
      _processingStatus = 'Авто-выравнивание, поворот и оцифровка накладной...';
    });

    try {
      // 1. Авто-выравнивание и распознавание накладной / чека через ИИ
      final doc = await _ocr.parseInvoiceWithVisionAi(_capturedPages);

      if (doc != null && doc.pagePhotos.isNotEmpty) {
        _capturedPages.clear();
        _capturedPages.addAll(doc.pagePhotos);
      }

      if (doc == null || doc.items.isEmpty) {
        setState(() => _isProcessing = false);
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: const Row(
                children: [
                  Icon(Icons.auto_fix_high_rounded, color: Colors.amber, size: 24),
                  SizedBox(width: 8),
                  Text('Повторить распознавание?', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: const Text(
                'Не удалось разобрать позиции таблицы. Проверьте правильность поворота листов (кнопка 🔄) или нажмите «Повторить через ИИ».',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _processInvoice();
                  },
                  child: const Text('Повторить через ИИ', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        }
        return;
      }

      // Проверка на повторное сканирование (дубликат накладной)
      final duplicate = await _storage.findDuplicateInvoice(doc.supplierName, doc.invoiceNumber);
      if (duplicate != null && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 28),
                SizedBox(width: 8),
                Text('Возможный дубликат!', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: Text(
              'Накладная №${doc.invoiceNumber} от "${doc.supplierName}" уже была сохранена ранее (${DateFormat("dd.MM.yyyy").format(duplicate.invoiceDate)} на сумму ${duplicate.totalAmount.toStringAsFixed(2)} TJS).\n\nВы уверены, что хотите продолжить оприходование?',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Всё равно открыть', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (proceed != true) {
          setState(() => _isProcessing = false);
          return;
        }
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
        TopNotification.showError(context, 'Ошибка обработки: $e');
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
                    // Кнопка ручной обрезки полей листа
                    if (!path.toLowerCase().endsWith('.pdf'))
                      IconButton(
                        icon: const Icon(Icons.crop_rounded, color: Color(0xFF10B981)),
                        tooltip: 'Обрезать поля',
                        onPressed: () => _showManualCropDialog(index),
                      ),
                    // Кнопка ручного поворота листа на 90°
                    if (!path.toLowerCase().endsWith('.pdf'))
                      IconButton(
                        icon: const Icon(Icons.rotate_right_rounded, color: Color(0xFF38BDF8)),
                        tooltip: 'Повернуть на 90°',
                        onPressed: () async {
                          final rotated = await ImageUtils.rotateImage90Degrees(File(path));
                          await FileImage(File(path)).evict();
                          setState(() {
                            _capturedPages[index] = rotated.path;
                          });
                          HapticFeedback.selectionClick();
                        },
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

  // Диалог ручной обрезки и выравнивания листа
  void _showManualCropDialog(int index) {
    if (index >= _capturedPages.length) return;
    String currentPath = _capturedPages[index];
    if (currentPath.toLowerCase().endsWith('.pdf')) {
      TopNotification.showInfo(context, 'PDF-документы не требуют обрезки.');
      return;
    }

    double topMargin = 0.0;
    double bottomMargin = 0.0;
    double leftMargin = 0.0;
    double rightMargin = 0.0;
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalCtx) => StatefulBuilder(
        builder: (ctx, setCropState) {
          final file = File(currentPath);

          return Container(
            height: MediaQuery.of(context).size.height * 0.90,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Лист #${index + 1}: Ручная обрезка и выравнивание',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(modalCtx),
                    ),
                  ],
                ),
                const Text(
                  'Настройте поля для удаления темных краев, стола или лишнего фона:',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 12),

                Expanded(
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.file(
                            file,
                            fit: BoxFit.contain,
                            key: ValueKey(currentPath),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: (topMargin * 2.5),
                            child: Container(color: Colors.redAccent.withOpacity(0.35)),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: (bottomMargin * 2.5),
                            child: Container(color: Colors.redAccent.withOpacity(0.35)),
                          ),
                          Positioned(
                            top: (topMargin * 2.5),
                            bottom: (bottomMargin * 2.5),
                            left: 0,
                            width: (leftMargin * 2.5),
                            child: Container(color: Colors.redAccent.withOpacity(0.35)),
                          ),
                          Positioned(
                            top: (topMargin * 2.5),
                            bottom: (bottomMargin * 2.5),
                            right: 0,
                            width: (rightMargin * 2.5),
                            child: Container(color: Colors.redAccent.withOpacity(0.35)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      icon: const Icon(Icons.rotate_right_rounded, color: Color(0xFF38BDF8), size: 18),
                      label: const Text('Повернуть 90°', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
                      onPressed: () async {
                        final rotated = await ImageUtils.rotateImage90Degrees(File(currentPath));
                        await FileImage(File(currentPath)).evict();
                        setCropState(() {
                          currentPath = rotated.path;
                        });
                        setState(() {
                          _capturedPages[index] = currentPath;
                        });
                      },
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 18),
                      label: const Text('Сбросить поля', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      onPressed: () {
                        setCropState(() {
                          topMargin = 0;
                          bottomMargin = 0;
                          leftMargin = 0;
                          rightMargin = 0;
                        });
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Сверху: ${topMargin.toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Slider(
                            value: topMargin,
                            min: 0,
                            max: 30,
                            activeColor: const Color(0xFF10B981),
                            onChanged: (v) => setCropState(() => topMargin = v),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Снизу: ${bottomMargin.toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Slider(
                            value: bottomMargin,
                            min: 0,
                            max: 30,
                            activeColor: const Color(0xFF10B981),
                            onChanged: (v) => setCropState(() => bottomMargin = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Слева: ${leftMargin.toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Slider(
                            value: leftMargin,
                            min: 0,
                            max: 30,
                            activeColor: const Color(0xFF10B981),
                            onChanged: (v) => setCropState(() => leftMargin = v),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Справа: ${rightMargin.toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Slider(
                            value: rightMargin,
                            min: 0,
                            max: 30,
                            activeColor: const Color(0xFF10B981),
                            onChanged: (v) => setCropState(() => rightMargin = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    minimumSize: const Size(double.infinity, 46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: isSaving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.crop_rounded, color: Colors.white),
                  label: Text(
                    isSaving ? 'Сохранение...' : 'Применить обрезку',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (topMargin == 0 && bottomMargin == 0 && leftMargin == 0 && rightMargin == 0) {
                            Navigator.pop(modalCtx);
                            return;
                          }

                          setCropState(() => isSaving = true);
                          final cropped = await ImageUtils.cropImageMargins(
                            File(currentPath),
                            topPercent: topMargin,
                            bottomPercent: bottomMargin,
                            leftPercent: leftMargin,
                            rightPercent: rightMargin,
                          );
                          await FileImage(File(currentPath)).evict();
                          await FileImage(cropped).evict();

                          if (mounted) {
                            setState(() {
                              _capturedPages[index] = cropped.path;
                            });
                          }
                          Navigator.pop(modalCtx);
                          TopNotification.showSuccess(context, 'Лист #${index + 1} успешно обрезан!');
                        },
                ),
              ],
            ),
          );
        },
      ),
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
