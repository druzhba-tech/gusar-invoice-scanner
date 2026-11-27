import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Встроенная камера с автоматическим кадрированием 1:1 (строгий квадрат)
/// для съёмки фотографий товаров без обрезки краёв.
class SquareCameraScreen extends StatefulWidget {
  const SquareCameraScreen({super.key});

  /// Открывает камеру 1:1 и возвращает снятый файл (или null при отмене).
  static Future<File?> capture(BuildContext context) {
    return Navigator.of(context).push<File?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const SquareCameraScreen(),
      ),
    );
  }

  @override
  State<SquareCameraScreen> createState() => _SquareCameraScreenState();
}

class _SquareCameraScreenState extends State<SquareCameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _errorMessage;

  FlashMode _flashMode = FlashMode.off;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  Offset? _focusPoint;
  File? _capturedFile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (mounted) {
        setState(() => _controller = null);
      } else {
        _controller = null;
      }
      controller.dispose();
    } else if (state == AppLifecycleState.resumed && _capturedFile == null) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (mounted) {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _isInitializing = false;
            _errorMessage = 'Камера не найдена на устройстве';
          });
        }
        return;
      }

      final backCam = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final prevController = _controller;
      _controller = null;
      await prevController?.dispose();

      final controller = CameraController(
        backCam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}

      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {}

      double minZ = 1.0;
      double maxZ = 1.0;
      try {
        minZ = await controller.getMinZoomLevel();
        maxZ = await controller.getMaxZoomLevel();
      } catch (_) {}

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _minZoom = minZ;
        _maxZoom = maxZ;
        _currentZoom = minZ.clamp(1.0, maxZ);
        _isInitializing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Не удалось запустить камеру 1:1: $e';
        });
      }
    }
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };

    try {
      await controller.setFlashMode(next);
      if (mounted) {
        setState(() => _flashMode = next);
      }
    } catch (_) {}
  }

  Future<void> _setZoom(double targetZoom) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final clamped = targetZoom.clamp(_minZoom, _maxZoom);
    try {
      await controller.setZoomLevel(clamped);
      if (mounted) {
        setState(() => _currentZoom = clamped);
      }
    } catch (_) {}
  }

  Future<void> _onTapToFocus(TapDownDetails details, double boxSize) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || boxSize <= 0) return;

    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final rawRatio = controller.value.aspectRatio > 0 ? controller.value.aspectRatio : (4 / 3);
    final ratio = rawRatio >= 1.0 ? rawRatio : (1.0 / rawRatio);

    double nx = (details.localPosition.dx / boxSize).clamp(0.0, 1.0);
    double ny = (details.localPosition.dy / boxSize).clamp(0.0, 1.0);

    if (isPortrait) {
      ny = (0.5 + (ny - 0.5) / ratio).clamp(0.0, 1.0);
    } else {
      nx = (0.5 + (nx - 0.5) / ratio).clamp(0.0, 1.0);
    }

    setState(() => _focusPoint = details.localPosition);

    try {
      await controller.setFocusPoint(Offset(nx, ny));
      await controller.setExposurePoint(Offset(nx, ny));
    } catch (_) {}

    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _focusPoint = null);
      }
    });
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      HapticFeedback.mediumImpact();
      final xfile = await controller.takePicture();
      if (_flashMode == FlashMode.torch) {
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _capturedFile = File(xfile.path);
          _isCapturing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCapturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка съёмки: $e')),
        );
      }
    }
  }

  Future<void> _fallbackToSystemCamera() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (picked != null && mounted) {
        Navigator.of(context).pop(File(picked.path));
      }
    } catch (_) {}
  }

  IconData get _flashIcon {
    return switch (_flashMode) {
      FlashMode.auto => Icons.flash_auto_rounded,
      FlashMode.torch => Icons.flashlight_on_rounded,
      _ => Icons.flash_off_rounded,
    };
  }

  String get _flashLabel {
    return switch (_flashMode) {
      FlashMode.auto => 'Авто',
      FlashMode.torch => 'Фонарь',
      _ => 'Выкл',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Верхняя панель управления
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF10B981).withOpacity(0.6)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.crop_square_rounded, size: 15, color: Color(0xFF34D399)),
                        SizedBox(width: 5),
                        Text(
                          'КАМЕРА 1:1',
                          style: TextStyle(
                            color: Color(0xFF34D399),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (_capturedFile == null && _controller != null && _controller!.value.isInitialized)
                    TextButton.icon(
                      onPressed: _cycleFlash,
                      icon: Icon(_flashIcon, color: _flashMode == FlashMode.off ? Colors.white70 : Colors.amberAccent, size: 20),
                      label: Text(
                        _flashLabel,
                        style: TextStyle(
                          color: _flashMode == FlashMode.off ? Colors.white70 : Colors.amberAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Поместите товар в центр квадрата 1:1',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),

            // Строгий квадрат видоискателя 1:1 по центру экрана
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF10B981), width: 2),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildSquareViewport(),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Быстрые кнопки зума (1x / 1.5x / 2x)
            if (_capturedFile == null && _controller != null && _controller!.value.isInitialized && _maxZoom > 1.2)
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final z in [1.0, 1.5, 2.0])
                      if (z <= _maxZoom + 0.05)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _setZoom(z),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: (_currentZoom - z).abs() < 0.2
                                    ? const Color(0xFF10B981)
                                    : Colors.white10,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                '${z == z.roundToDouble() ? z.toStringAsFixed(0) : z.toStringAsFixed(1)}×',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),

            // Нижняя панель затвора или подтверждения снимка
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
              child: _capturedFile != null
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white30),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Переснять', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: () {
                              setState(() => _capturedFile = null);
                              if (_flashMode == FlashMode.torch) {
                                _controller?.setFlashMode(FlashMode.torch).catchError((_) {});
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            icon: const Icon(Icons.check_rounded),
                            label: const Text('Готово (1:1)', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: () => Navigator.of(context).pop(_capturedFile),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          onPressed: _fallbackToSystemCamera,
                          tooltip: 'Системная камера',
                          icon: const Icon(Icons.open_in_new_rounded, color: Colors.white54, size: 24),
                        ),
                        GestureDetector(
                          onTap: _isCapturing ? null : _capturePhoto,
                          child: Container(
                            width: 76,
                            height: 76,
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3.5),
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _isCapturing ? Colors.white54 : const Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                              child: _isCapturing
                                  ? const Padding(
                                      padding: EdgeInsets.all(18),
                                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                    )
                                  : const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 30),
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSquareViewport() {
    if (_capturedFile != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(_capturedFile!, fit: BoxFit.cover),
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Формат 1:1',
                style: TextStyle(color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      );
    }

    if (_isInitializing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF10B981)),
            SizedBox(height: 12),
            Text('Запуск камеры 1:1...', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      );
    }

    if (_errorMessage != null || _controller == null || !_controller!.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_rounded, color: Colors.amberAccent, size: 42),
              const SizedBox(height: 10),
              Text(
                _errorMessage ?? 'Камера недоступна',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                onPressed: _fallbackToSystemCamera,
                icon: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
                label: const Text('Открыть системную камеру', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller!;
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final rawRatio = controller.value.aspectRatio > 0 ? controller.value.aspectRatio : (4 / 3);
    final normRatio = max(rawRatio, 1.0 / rawRatio);
    final previewW = isPortrait ? 100.0 : 100.0 * normRatio;
    final previewH = isPortrait ? 100.0 * normRatio : 100.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final boxSize = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _onTapToFocus(d, boxSize),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: previewW,
                  height: previewH,
                  child: CameraPreview(controller),
                ),
              ),
              // Лёгкая сетка 3x3 и центральный маркер для ровного кадрирования
              IgnorePointer(
                child: CustomPaint(
                  painter: _SquareGridPainter(),
                ),
              ),
              if (_focusPoint != null)
                Positioned(
                  left: (_focusPoint!.dx - 26).clamp(4.0, max(4.0, boxSize - 56)),
                  top: (_focusPoint!.dy - 26).clamp(4.0, max(4.0, boxSize - 56)),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.amberAccent, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SquareGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.18)
      ..strokeWidth = 1;

    final thirdW = size.width / 3;
    final thirdH = size.height / 3;

    canvas.drawLine(Offset(thirdW, 0), Offset(thirdW, size.height), paint);
    canvas.drawLine(Offset(thirdW * 2, 0), Offset(thirdW * 2, size.height), paint);
    canvas.drawLine(Offset(0, thirdH), Offset(size.width, thirdH), paint);
    canvas.drawLine(Offset(0, thirdH * 2), Offset(size.width, thirdH * 2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
