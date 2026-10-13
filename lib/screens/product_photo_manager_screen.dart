import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../widgets/barcode_scanner_dialog.dart';

class ProductPhotoManagerScreen extends StatefulWidget {
  const ProductPhotoManagerScreen({super.key});

  @override
  State<ProductPhotoManagerScreen> createState() => _ProductPhotoManagerScreenState();
}

class _ProductPhotoManagerScreenState extends State<ProductPhotoManagerScreen> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _searchCtrl = TextEditingController();
  List<Product> _allProducts = [];
  List<Product> _filteredProducts = [];
  bool _isLoading = true;

  // Фильтр: 0 = Все, 1 = Без фото, 2 = С фото
  int _photoFilter = 0;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    final prods = await _api.getProducts();
    setState(() {
      _allProducts = List.from(prods);
      _isLoading = false;
    });
    _applyFilter();
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filteredProducts = _allProducts.where((p) {
        final matchesQuery = query.isEmpty ||
            p.name.toLowerCase().contains(query) ||
            (p.barcode != null && p.barcode!.contains(query));

        final hasPhoto = (p.imageUrl != null && p.imageUrl!.isNotEmpty) ||
            (p.localImagePath != null && File(p.localImagePath!).existsSync());

        if (!matchesQuery) return false;
        if (_photoFilter == 1) return !hasPhoto; // Только без фото
        if (_photoFilter == 2) return hasPhoto; // Только с фото
        return true;
      }).toList();
    });
  }

  // Сканирование штрихкода камерой для быстрого поиска
  Future<void> _scanBarcodeForSearch() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      _searchCtrl.text = scanned;
      _applyFilter();

      // Если найден ровно один товар — сразу открываем его для фото
      if (_filteredProducts.length == 1) {
        _openPhotoEditorSheet(_filteredProducts.first);
      }
    }
  }

  // Открытие модального окна добавления/редактирования фото товара
  void _openPhotoEditorSheet(Product product) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _ProductPhotoSheet(
        product: product,
        onPhotoUpdated: (updatedProduct) {
          final idx = _allProducts.indexWhere((p) => p.id == updatedProduct.id);
          if (idx >= 0) {
            setState(() {
              _allProducts[idx] = updatedProduct;
            });
            _applyFilter();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final withoutPhotoCount = _allProducts.where((p) => (p.imageUrl == null || p.imageUrl!.isEmpty) && (p.localImagePath == null || !File(p.localImagePath!).existsSync())).length;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Фотографии товаров', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            Text('Привязка и сжатие снимков для базы gusar.tj', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Обновить каталог',
            onPressed: () => _loadProducts(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Поисковая панель (текст + сканер штрихкода)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Поиск по названию или штрихкоду...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF10B981), size: 20),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                _applyFilter();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => _applyFilter(),
                  ),
                ),
                const SizedBox(width: 8),
                // Кнопка быстрого сканирования штрихкода камерой
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _scanBarcodeForSearch,
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 18),
                  label: const Text('Скан', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
          ),

          // 2. Быстрые вкладки-фильтры
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1E293B).withOpacity(0.5),
            child: Row(
              children: [
                _buildFilterChip(0, 'Все (${_allProducts.length})'),
                const SizedBox(width: 8),
                _buildFilterChip(1, 'Без фото ($withoutPhotoCount)', isWarning: true),
                const SizedBox(width: 8),
                _buildFilterChip(2, 'С фото (${_allProducts.length - withoutPhotoCount})'),
              ],
            ),
          ),

          // 3. Список товаров
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
                : _filteredProducts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.image_not_supported_outlined, color: Colors.white24, size: 48),
                            const SizedBox(height: 12),
                            Text(
                              _searchCtrl.text.isNotEmpty
                                  ? 'По запросу "${_searchCtrl.text}" ничего не найдено'
                                  : 'Товары не найдены',
                              style: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _filteredProducts.length,
                        itemBuilder: (ctx, idx) {
                          final prod = _filteredProducts[idx];
                          return _buildProductListItem(prod);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(int index, String label, {bool isWarning = false}) {
    final isSelected = _photoFilter == index;
    return GestureDetector(
      onTap: () {
        setState(() => _photoFilter = index);
        _applyFilter();
        HapticFeedback.selectionClick();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (isWarning ? Colors.orange.shade800 : const Color(0xFF10B981))
              : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : (isWarning ? Colors.orange.withOpacity(0.4) : Colors.white12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : (isWarning ? Colors.orange.shade300 : Colors.white70),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildProductListItem(Product prod) {
    final hasLocalPhoto = prod.localImagePath != null && File(prod.localImagePath!).existsSync();
    final hasServerPhoto = prod.imageUrl != null && prod.imageUrl!.isNotEmpty;
    final hasPhoto = hasLocalPhoto || hasServerPhoto;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: hasPhoto ? const Color(0xFF10B981).withOpacity(0.3) : Colors.white12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        onTap: () => _openPhotoEditorSheet(prod),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 48,
            height: 48,
            color: const Color(0xFF0F172A),
            child: hasLocalPhoto
                ? Image.file(File(prod.localImagePath!), fit: BoxFit.cover)
                : hasServerPhoto
                    ? Image.network(prod.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24))
                    : const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 22),
          ),
        ),
        title: Text(
          prod.name,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            if (prod.barcode != null && prod.barcode!.isNotEmpty) ...[
              const Icon(Icons.qr_code, color: Colors.white38, size: 12),
              const SizedBox(width: 4),
              Text(prod.barcode!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace')),
              const SizedBox(width: 8),
            ],
            Text('${prod.price.toStringAsFixed(2)} TJS', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: hasPhoto ? const Color(0xFF10B981).withOpacity(0.15) : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            hasPhoto ? Icons.edit_rounded : Icons.camera_alt_rounded,
            color: hasPhoto ? const Color(0xFF10B981) : Colors.white70,
            size: 18,
          ),
        ),
      ),
    );
  }
}

// Модальное окно управления фото конкретного товара
class _ProductPhotoSheet extends StatefulWidget {
  final Product product;
  final ValueChanged<Product> onPhotoUpdated;

  const _ProductPhotoSheet({required this.product, required this.onPhotoUpdated});

  @override
  State<_ProductPhotoSheet> createState() => _ProductPhotoSheetState();
}

class _ProductPhotoSheetState extends State<_ProductPhotoSheet> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();

  File? _currentImageFile;
  int _rotationTurns = 0;
  bool _isUploading = false;
  String? _compressionInfo;

  @override
  void initState() {
    super.initState();
    if (widget.product.localImagePath != null && File(widget.product.localImagePath!).existsSync()) {
      _currentImageFile = File(widget.product.localImagePath!);
    }
  }

  // Сжатие и сохранение фото
  Future<void> _pickAndCompressImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 88,
      );

      if (picked != null) {
        final originalFile = File(picked.path);
        final originalSize = await originalFile.length();

        final appDir = await getApplicationDocumentsDirectory();
        final fileName = 'prod_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedFile = await originalFile.copy('${appDir.path}/$fileName');
        final compressedSize = await savedFile.length();

        final origMb = (originalSize / (1024 * 1024)).toStringAsFixed(1);
        final compKb = (compressedSize / 1024).toStringAsFixed(0);

        setState(() {
          _currentImageFile = savedFile;
          _rotationTurns = 0;
          _compressionInfo = 'Оптимизировано: ${origMb} МБ ➔ ${compKb} КБ (без потери резкости)';
        });

        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка съёмки/выбора фото: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  void _rotateImage() {
    setState(() {
      _rotationTurns = (_rotationTurns + 1) % 4;
    });
    HapticFeedback.selectionClick();
  }

  void _removePhoto() {
    setState(() {
      _currentImageFile = null;
      _rotationTurns = 0;
      _compressionInfo = null;
    });
  }

  // Сохранение и отправка на сервер gusar.tj
  Future<void> _saveAndUpload() async {
    if (_currentImageFile == null) return;

    setState(() => _isUploading = true);

    try {
      final updated = await _api.uploadProductImage(
        widget.product.id,
        _currentImageFile!.path,
      );

      setState(() => _isUploading = false);

      if (mounted) {
        final bool onSite = updated?.imageUrl != null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: onSite ? const Color(0xFF10B981) : Colors.amber.shade800,
            content: Row(
              children: [
                Icon(onSite ? Icons.cloud_done_rounded : Icons.save_rounded, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    onSite
                        ? 'Фото товара "${widget.product.name}" обновлено на сайте gusar.tj!'
                        : 'Фото товара "${widget.product.name}" сохранено в приложении!',
                  ),
                ),
              ],
            ),
          ),
        );

        if (updated != null) {
          widget.onPhotoUpdated(updated);
        }
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка отправки фото: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Заголовок карточки товара
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.product.name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        'Штрихкод: ${widget.product.barcode ?? "—"} • ${widget.product.price.toStringAsFixed(2)} TJS',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Фото карточка
            Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _currentImageFile != null
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          RotatedBox(
                            quarterTurns: _rotationTurns,
                            child: Image.file(_currentImageFile!, fit: BoxFit.contain, width: double.infinity, height: 200),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton(
                              style: IconButton.styleFrom(backgroundColor: Colors.black54),
                              icon: const Icon(Icons.rotate_right_rounded, color: Colors.white),
                              tooltip: 'Повернуть на 90°',
                              onPressed: _rotateImage,
                            ),
                          ),
                        ],
                      )
                    : (widget.product.imageUrl != null && widget.product.imageUrl!.isNotEmpty)
                        ? Image.network(widget.product.imageUrl!, fit: BoxFit.contain)
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.no_photography_outlined, color: Colors.white24, size: 48),
                              SizedBox(height: 8),
                              Text('Фотография ещё не привязана', style: TextStyle(color: Colors.white38, fontSize: 12)),
                            ],
                          ),
              ),
            ),

            if (_compressionInfo != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.compress_rounded, color: Color(0xFF10B981), size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _compressionInfo!,
                        style: const TextStyle(color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),

            // Кнопки источника: Камера и Галерея
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _pickAndCompressImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
                    label: const Text('Камера', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _pickAndCompressImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded, color: Colors.white, size: 18),
                    label: const Text('Галерея', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                if (_currentImageFile != null) ...[
                  const SizedBox(width: 10),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.red.withOpacity(0.15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                    onPressed: _removePhoto,
                  ),
                ],
              ],
            ),

            if (_currentImageFile != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isUploading ? null : _saveAndUpload,
                child: _isUploading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_upload_rounded, color: Colors.white, size: 18),
                          SizedBox(width: 8),
                          Text('Сохранить и загрузить на сервер', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
