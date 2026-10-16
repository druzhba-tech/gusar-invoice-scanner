import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// Фоновый воркер поворота изображения в отдельном изоляте (не блокирует UI)
Uint8List? _rotateComputeWorker(Map<String, dynamic> args) {
  try {
    final Uint8List bytes = args['bytes'];
    final int angle = args['angle'];
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return null;
    image = img.bakeOrientation(image);
    final rotated = img.copyRotate(image, angle: angle);
    return Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
  } catch (e) {
    print('_rotateComputeWorker error: $e');
    return null;
  }
}

/// Фоновый воркер обрезки и поворота изображения в отдельном изоляте
Uint8List? _cropComputeWorker(Map<String, dynamic> args) {
  try {
    final Uint8List bytes = args['bytes'];
    final double leftFraction = args['leftFraction'];
    final double rightFraction = args['rightFraction'];
    final double topFraction = args['topFraction'];
    final double bottomFraction = args['bottomFraction'];
    final int quarterTurns = args['quarterTurns'] ?? 0;
    final int quality = args['quality'] ?? 92;

    img.Image? image = img.decodeImage(bytes);
    if (image == null) return null;

    image = img.bakeOrientation(image);

    final normalizedTurns = ((quarterTurns % 4) + 4) % 4;
    if (normalizedTurns != 0) {
      image = img.copyRotate(image, angle: normalizedTurns * 90);
    }

    int cropX = (image.width * leftFraction).round();
    int cropY = (image.height * topFraction).round();
    int cropW = (image.width * (1.0 - leftFraction - rightFraction)).round();
    int cropH = (image.height * (1.0 - topFraction - bottomFraction)).round();

    if (cropW >= 50 && cropH >= 50 && (leftFraction > 0 || rightFraction > 0 || topFraction > 0 || bottomFraction > 0)) {
      image = img.copyCrop(image, x: cropX, y: cropY, width: cropW, height: cropH);
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  } catch (e) {
    print('_cropComputeWorker error: $e');
    return null;
  }
}

/// Утилита для обработки фотографий товаров и документов:
/// 1. Приведение к квадратному формату 1:1 (центр-кроп) для товаров
/// 2. Коррекция EXIF-ориентации снимков с камеры
/// 3. Физический поворот фото на 90° в обе стороны
/// 4. Авто-выравнивание (auto-orientation/deskew) накладных перед чтением нейросетью
/// 5. Быстрое сжатие до оптимального размера без потери качества
class ImageUtils {
  /// Быстрый поворот файла изображения в фоновом изоляте compute()
  /// quarterTurns: 1 = +90° (вправо), 2 = 180°, 3 = +270° (или -90° влево)
  static Future<File> rotateImageByQuarterTurns(File sourceFile, int quarterTurns, {String? targetPath}) async {
    final turns = ((quarterTurns % 4) + 4) % 4;
    if (turns == 0) return sourceFile;

    try {
      final outPath = targetPath ?? sourceFile.path;
      final bytes = await sourceFile.readAsBytes();

      final rotatedBytes = await compute(_rotateComputeWorker, {
        'bytes': bytes,
        'angle': turns * 90,
      });

      if (rotatedBytes == null) return sourceFile;
      final outFile = File(outPath);
      await outFile.writeAsBytes(rotatedBytes);
      return outFile;
    } catch (e) {
      print('rotateImageByQuarterTurns error: $e');
      return sourceFile;
    }
  }

  /// Физический поворот файла изображения на 90 градусов по часовой стрелке (вправо)
  static Future<File> rotateImage90Degrees(File sourceFile, {String? targetPath}) async {
    return rotateImageByQuarterTurns(sourceFile, 1, targetPath: targetPath);
  }

  /// Физический поворот файла изображения на 90 градусов против часовой стрелки (влево)
  static Future<File> rotateImageMinus90Degrees(File sourceFile, {String? targetPath}) async {
    return rotateImageByQuarterTurns(sourceFile, 3, targetPath: targetPath);
  }

  /// Автоматическое выравнивание листа накладной:
  /// ПРАВИЛО FAST-PATH: Если документ уже сфотографирован правильно (вертикальный снимок,
  /// текст расположен горизонтально, угол 0°), тяжёлый шаг декодирования в память и поворота
  /// ПОЛНОСТЬЮ ПРОПУСКАЕТСЯ! Это экономит 6-10 секунд на каждый лист!
  static Future<File> autoStraightenInvoiceImage(File sourceFile, {TextRecognizer? recognizer}) async {
    try {
      int rotateAngle = 0;

      // 1. Проверка угла строк текста через нативный ML Kit
      if (recognizer != null) {
        try {
          final inputImage = InputImage.fromFile(sourceFile);
          final recognizedText = await recognizer.processImage(inputImage);

          int verticalLines = 0;
          int horizontalLines = 0;
          double totalAngle = 0;
          int angleCount = 0;

          for (final block in recognizedText.blocks) {
            for (final line in block.lines) {
              final box = line.boundingBox;
              if (box.width > box.height * 1.3) {
                horizontalLines++;
              } else if (box.height > box.width * 1.3) {
                verticalLines++;
              }

              if (line.angle != null) {
                totalAngle += line.angle!;
                angleCount++;
              }
            }
          }

          if (angleCount > 0) {
            final avgAngle = (totalAngle / angleCount) % 360;
            if (avgAngle >= 45 && avgAngle < 135) {
              rotateAngle = 270;
            } else if (avgAngle >= 135 && avgAngle < 225) {
              rotateAngle = 180;
            } else if (avgAngle >= 225 && avgAngle < 315) {
              rotateAngle = 90;
            }
          } else if (verticalLines > horizontalLines * 1.3 && verticalLines >= 3) {
            rotateAngle = 90;
          }
        } catch (_) {}
      }

      // Если поворот не требуется, возвращаем исходный файл без лишнего пережатия
      if (rotateAngle == 0) {
        return sourceFile;
      }

      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      image = img.bakeOrientation(image);
      image = img.copyRotate(image, angle: rotateAngle);

      final jpgBytes = Uint8List.fromList(img.encodeJpg(image, quality: 90));
      await sourceFile.writeAsBytes(jpgBytes);
      return sourceFile;
    } catch (e) {
      print('autoStraightenInvoiceImage error: $e');
      return sourceFile;
    }
  }

  /// Быстрая подготовка файла для отправки в Vision AI (Gemini / Yandex):
  /// Ограничивает длинную сторону до 1920px (Full HD) с сохранением кристальной резкости шрифта.
  /// Снижает вес с 10 МБ до 350-500 КБ, что ускоряет загрузку в облако по сети в 10-15 раз!
  static Future<File> prepareImageForAiUpload(File sourceFile) async {
    try {
      final length = await sourceFile.length();
      // Если файл уже компактный (< 900 КБ), отправляем сразу без задержек
      if (length <= 900 * 1024) {
        return sourceFile;
      }

      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      image = img.bakeOrientation(image);

      // Масштабируем до разумного оптимума нейросетей (1920px по большей стороне)
      const maxDim = 1920;
      if (image.width > maxDim || image.height > maxDim) {
        if (image.width >= image.height) {
          image = img.copyResize(image, width: maxDim, interpolation: img.Interpolation.linear);
        } else {
          image = img.copyResize(image, height: maxDim, interpolation: img.Interpolation.linear);
        }
      }

      final compressedBytes = Uint8List.fromList(img.encodeJpg(image, quality: 85));
      final outPath = '${sourceFile.parent.path}/ai_opt_${DateTime.now().millisecondsSinceEpoch}_${sourceFile.uri.pathSegments.last}';
      final outFile = File(outPath);
      await outFile.writeAsBytes(compressedBytes);
      return outFile;
    } catch (e) {
      print('prepareImageForAiUpload error: $e');
      return sourceFile;
    }
  }

  /// Сжимает изображение до строго заданного максимального размера в килобайтах (по умолчанию 40 КБ)
  /// с сохранением отличной детализации и чёткости этикетки/товара.
  static Uint8List compressImageToMaxKb(
    img.Image sourceImage, {
    int maxKb = 40,
    int initialQuality = 80,
  }) {
    final maxBytes = maxKb * 1024;
    var currentImg = sourceImage;
    int currentQuality = initialQuality;

    // Шаг 1: если изображение слишком большое по разрешению (> 600x600),
    // уменьшаем его до 550x550, что даёт высокую чёткость и минимальный вес
    if (currentImg.width > 600 || currentImg.height > 600) {
      final targetSide = min(currentImg.width, 550);
      currentImg = img.copyResize(
        currentImg,
        width: targetSide,
        height: targetSide,
        interpolation: img.Interpolation.linear,
      );
    }

    Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: currentQuality));
    if (jpgBytes.length <= maxBytes) {
      return jpgBytes;
    }

    // Шаг 2: постепенная регулировка качества JPEG
    final qualitySteps = [74, 66, 58, 50, 42, 35];
    for (final q in qualitySteps) {
      currentQuality = q;
      jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: currentQuality));
      if (jpgBytes.length <= maxBytes) {
        return jpgBytes;
      }
    }

    // Шаг 3: если всё ещё больше 40 КБ (сложные текстуры), масштабируем разрешение:
    final resizeSteps = [450, 380, 320, 260];
    for (final side in resizeSteps) {
      if (currentImg.width > side) {
        currentImg = img.copyResize(
          currentImg,
          width: side,
          height: side,
          interpolation: img.Interpolation.linear,
        );
      }
      for (final q in [65, 52, 40, 30]) {
        jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: q));
        if (jpgBytes.length <= maxBytes) {
          return jpgBytes;
        }
      }
    }

    return jpgBytes;
  }

  /// Обрезает фото до строгого квадрата 1:1 по центру, применяет ориентацию и сжимает строго до maxKb (по умолчанию 40 КБ)
  static Future<File> cropToSquareAndCompress(
    File sourceFile,
    String targetPath, {
    int maxSize = 600,
    int quality = 80,
    int quarterTurns = 0,
    int maxKb = 40,
  }) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) {
        return await sourceFile.copy(targetPath);
      }

      // 1. Нормализуем ориентацию сенсора камеры (EXIF)
      image = img.bakeOrientation(image);

      // 2. Если пользователь повернул фото вручную (на 90, 180, 270 град)
      final normalizedTurns = quarterTurns % 4;
      if (normalizedTurns != 0) {
        image = img.copyRotate(image, angle: normalizedTurns * 90);
      }

      // 3. Вырезаем строго квадрат 1:1 по центру
      final side = min(image.width, image.height);
      final cropX = (image.width - side) ~/ 2;
      final cropY = (image.height - side) ~/ 2;

      var squareImage = img.copyCrop(
        image,
        x: cropX,
        y: cropY,
        width: side,
        height: side,
      );

      // 4. Масштабируем до разумного максимума (по умолчанию 550x550)
      if (side > maxSize) {
        squareImage = img.copyResize(
          squareImage,
          width: maxSize,
          height: maxSize,
          interpolation: img.Interpolation.linear,
        );
      }

      // 5. Кодируем строго до лимита maxKb (по умолчанию 40 КБ)
      final Uint8List jpgBytes = compressImageToMaxKb(
        squareImage,
        maxKb: maxKb,
        initialQuality: quality,
      );

      final targetFile = File(targetPath);
      await targetFile.writeAsBytes(jpgBytes);
      return targetFile;
    } catch (e) {
      // При любой ошибке отдаем копию файла
      return await sourceFile.copy(targetPath);
    }
  }

  /// Утилита для сжатия любого файла изображения строго до maxKb (по умолчанию 40 КБ)
  static Future<File> compressFileToMaxKb(
    File sourceFile, {
    String? targetPath,
    int maxKb = 40,
  }) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      if (bytes.length <= maxKb * 1024) {
        if (targetPath != null && targetPath != sourceFile.path) {
          return await sourceFile.copy(targetPath);
        }
        return sourceFile;
      }

      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      image = img.bakeOrientation(image);
      final compressedBytes = compressImageToMaxKb(image, maxKb: maxKb);

      final outPath = targetPath ?? sourceFile.path;
      final outFile = File(outPath);
      await outFile.writeAsBytes(compressedBytes);
      return outFile;
    } catch (e) {
      print('compressFileToMaxKb error: $e');
      return sourceFile;
    }
  }

  /// Ручная обрезка полей листа накладной в процентах (0.0 - 45.0) с опциональным поворотом
  static Future<File> cropImageMargins(
    File sourceFile, {
    double topPercent = 0.0,
    double bottomPercent = 0.0,
    double leftPercent = 0.0,
    double rightPercent = 0.0,
    int quarterTurns = 0,
    int quality = 92,
  }) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      final croppedBytes = await compute(_cropComputeWorker, {
        'bytes': bytes,
        'topFraction': topPercent.clamp(0.0, 45.0) / 100.0,
        'bottomFraction': bottomPercent.clamp(0.0, 45.0) / 100.0,
        'leftFraction': leftPercent.clamp(0.0, 45.0) / 100.0,
        'rightFraction': rightPercent.clamp(0.0, 45.0) / 100.0,
        'quarterTurns': quarterTurns,
        'quality': quality,
      });

      if (croppedBytes == null) return sourceFile;

      final outPath = '${sourceFile.parent.path}/crop_${DateTime.now().millisecondsSinceEpoch}_${sourceFile.uri.pathSegments.last}';
      final outFile = File(outPath);
      await outFile.writeAsBytes(croppedBytes);
      return outFile;
    } catch (e) {
      print('cropImageMargins error: $e');
      return sourceFile;
    }
  }
}
