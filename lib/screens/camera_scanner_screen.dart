import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import '../models/invoice_document.dart';
import '../services/ocr_service.dart';
import '../services/matching_service.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import 'invoice_review_screen.dart';

class CameraScannerScreen extends StatefulWidget {
  final List<String>? preselectedImages;

  const CameraScannerScreen({super.key, this.preselectedImages});

  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen> {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;
  bool _isFlashOn = false;

  final List<String> _capturedPages = [];
  bool _isProcessing = false;
  String _processingStatus = 'Анализ документа...';

  final OcrService _ocr = OcrService();
  final MatchingService _matcher = MatchingService();
  final ApiService _api = ApiService();
  final LocalStorageService _storage = LocalStorageService();

  @override
  void initState() {
    super.initState();
    if (widget.preselectedImages != null && widget.preselectedImages!.isNotEmpty) {
      _capturedPages.addAll(widget.preselectedImages!);
    }
    _initCamera();
    _matcher.init();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _cameraController = CameraController(
          _cameras.first,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await _cameraController!.initialize();
        if (mounted) setState(() => _isCameraReady = true);
      }
    } catch (e) {
      print('Camera error: $e');
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    _isFlashOn = !_isFlashOn;
    await _cameraController!.setFlashMode(_isFlashOn ? FlashMode.torch : FlashMode.off);
    setState(() {});
  }

  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      final image = await _cameraController!.takePicture();
      setState(() {
        _capturedPages.add(image.path);
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка съёмки: $e')));
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _capturedPages.add(image.path);
      });
    }
  }

  Future<void> _processInvoice() async {
    if (_capturedPages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сделайте хотя бы одно фото накладной!')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _processingStatus = 'Нейросеть читает накладную (Gemini Vision)...';
    });

    try {
      // 1. Распознавание накладной / чека
      final doc = await _ocr.parseInvoiceWithVisionAi(_capturedPages);

      if (doc == null || doc.items.isEmpty) {
        setState(() => _isProcessing = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось разобрать таблицу товаров. Попробуйте сфотографировать четче.')),
          );
        }
        return;
      }

      setState(() => _processingStatus = 'Автоматическое сопоставление с базой gusar.tj...');

      // 2. Получение каталога и умное сопоставление
      final catalog = await _api.getProducts();
      _matcher.autoMatchDocument(doc, catalog);

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка обработки: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Видоискатель камеры
          if (_isCameraReady && _cameraController != null)
            SizedBox.expand(child: CameraPreview(_cameraController!))
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_outlined, color: Colors.white24, size: 64),
                  SizedBox(height: 12),
                  Text('Инициализация камеры...', style: TextStyle(color: Colors.white54)),
                ],
              ),
            ),

          // 2. Рамка кадрирования документа (Overlay)
          SafeArea(
            child: Column(
              children: [
                // Верхняя панель
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Страниц: ${_capturedPages.length}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: Icon(_isFlashOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                        onPressed: _toggleFlash,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Рамка подсказки формата А4 / чека
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  height: 380,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF10B981), width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Text(
                      'Поместите накладную или чек в рамку',
                      style: TextStyle(color: Colors.white70, backgroundColor: Colors.black54, fontSize: 13),
                    ),
                  ),
                ),

                const Spacer(),

                // 3. Карусель миниатюр отснятых страниц (Многостраничный режим)
                if (_capturedPages.isNotEmpty)
                  Container(
                    height: 70,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _capturedPages.length,
                      itemBuilder: (ctx, i) {
                        return Stack(
                          children: [
                            Container(
                              margin: const EdgeInsets.only(right: 10),
                              width: 55,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF10B981), width: 2),
                                image: DecorationImage(
                                  image: FileImage(File(_capturedPages[i])),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 2,
                              right: 12,
                              child: GestureDetector(
                                onTap: () => setState(() => _capturedPages.removeAt(i)),
                                child: const CircleAvatar(
                                  radius: 10,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close, size: 12, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                // 4. Нижняя панель съёмки
                Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      // Кнопка галереи
                      IconButton(
                        icon: const Icon(Icons.photo_library_outlined, color: Colors.white, size: 28),
                        onPressed: _pickFromGallery,
                      ),

                      // Кнопка затвора
                      GestureDetector(
                        onTap: _takePicture,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ),
                      ),

                      // Кнопка готово (Обработать)
                      if (_capturedPages.isNotEmpty)
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          onPressed: _processInvoice,
                          child: const Text('Готово', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 5. Окно загрузки и AI распознавания
          if (_isProcessing)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF10B981)),
                    const SizedBox(height: 20),
                    Text(_processingStatus, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Проверяем математику и связки номенклатуры...', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
