import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../utils/image_utils.dart';
import '../utils/top_notification.dart';
import '../widgets/barcode_scanner_dialog.dart';
import '../widgets/product_image_widget.dart';
import 'add_product_screen.dart';

typedef LinkedProductsScreen = ProductPhotoManagerScreen;

class ProductPhotoManagerScreen extends StatefulWidget {
  const ProductPhotoManagerScreen({super.key});

  @override
  State<ProductPhotoManagerScreen> createState() => _ProductPhotoManagerScreenState();
}

class _ProductPhotoManagerScreenState extends State<ProductPhotoManagerScreen> {
  final ApiService _api = ApiService();

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<Product> _allProducts = [];
  List<Product> _filteredProducts = [];
  bool _isLoading = true;

  // Фильтр: 0 = Все, 1 = Без фото, 2 = С фото
  int _photoFilter = 0;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadProducts({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    final prods = await _api.getProducts(forceRefresh: forceRefresh);
    if (mounted) {
      setState(() {
        _allProducts = List.from(prods);
        _isLoading = false;
      });
      _applyFilter();
    }
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filteredProducts = _allProducts.where((p) {
        final matchesQuery = query.isEmpty ||
            p.name.toLowerCase().contains(query) ||
            (p.barcode != null && p.barcode!.contains(query)) ||
            (p.category != null && p.category!.toLowerCase().contains(query)) ||
            (p.pluCode != null && p.pluCode!.contains(query));

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

      // Если найден ровно один товар — сразу открываем окно редактирования
      if (_filteredProducts.length == 1) {
        await _openProductEditorSheet(_filteredProducts.first);
      }
    }
    if (mounted) {
      _searchFocusNode.requestFocus();
    }
  }

  // Открытие модального окна редактирования товара (фото, цены, штрихкод, ед. изм)
  Future<void> _openProductEditorSheet(Product product) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _ProductEditorSheet(
        product: product,
        onProductUpdated: (updatedProduct) {
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
    if (mounted) {
      _searchFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final withoutPhotoCount = _allProducts.where((p) =>
        (p.imageUrl == null || p.imageUrl!.isEmpty) &&
        (p.localImagePath == null || !File(p.localImagePath!).existsSync())).length;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Связанные товары',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'Каталог gusar.tj • Редактирование цен, штрихкодов и фото',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          // Добавление нового товара в базу
          IconButton(
            icon: const Icon(Icons.add_box_rounded, color: Color(0xFF10B981)),
            tooltip: 'Добавить новый товар',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddProductScreen()),
              ).then((created) {
                if (created != null) {
                  _loadProducts(forceRefresh: true);
                }
              });
            },
          ),
          // Обновление каталога с сервера
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Обновить товары с gusar.tj',
            onPressed: () => _loadProducts(forceRefresh: true),
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
                    focusNode: _searchFocusNode,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
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
                                _searchFocusNode.requestFocus();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.2),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF10B981), width: 2),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onChanged: (_) => _applyFilter(),
                    onSubmitted: (_) {
                      _applyFilter();
                      if (_filteredProducts.length == 1) {
                        _openProductEditorSheet(_filteredProducts.first);
                      }
                    },
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
                            const Icon(Icons.inventory_2_outlined, color: Colors.white24, size: 54),
                            const SizedBox(height: 12),
                            Text(
                              _searchCtrl.text.isNotEmpty
                                  ? 'По запросу "${_searchCtrl.text}" товары не найдены'
                                  : 'Товары в каталоге не найдены',
                              style: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () => _loadProducts(forceRefresh: true),
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Перезагрузить каталог'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        color: const Color(0xFF10B981),
                        backgroundColor: const Color(0xFF1E293B),
                        onRefresh: () => _loadProducts(forceRefresh: true),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          itemCount: _filteredProducts.length,
                          itemBuilder: (ctx, idx) {
                            final prod = _filteredProducts[idx];
                            return _buildProductListItem(prod);
                          },
                        ),
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
        _searchFocusNode.requestFocus();
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
        border: Border.all(color: hasPhoto ? const Color(0xFF10B981).withOpacity(0.35) : Colors.white12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openProductEditorSheet(prod),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Превью фото товара
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 54,
                  height: 54,
                  color: const Color(0xFF0F172A),
                  child: hasPhoto
                      ? ProductImageWidget(
                          imageUrl: prod.imageUrl,
                          localImagePath: prod.localImagePath,
                          fit: BoxFit.cover,
                          width: 54,
                          height: 54,
                          placeholder: const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 24),
                        )
                      : const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 24),
                ),
              ),
              const SizedBox(width: 12),

              // Информация о товаре
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prod.name,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),

                    // Штрихкод и категория
                    Row(
                      children: [
                        if (prod.barcode != null && prod.barcode!.isNotEmpty) ...[
                          const Icon(Icons.qr_code, color: Colors.white38, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            prod.barcode!,
                            style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (prod.category != null && prod.category!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              prod.category!,
                              style: const TextStyle(color: Colors.white60, fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Цены (розница и себестоимость)
                    Row(
                      children: [
                        Text(
                          '${prod.price.toStringAsFixed(2)} TJS',
                          style: const TextStyle(color: Color(0xFF10B981), fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        if (prod.costPrice > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            'закуп: ${prod.costPrice.toStringAsFixed(2)} TJS',
                            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          '(${prod.unit})',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Кнопка редактирования
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.3)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_rounded, color: Color(0xFF38BDF8), size: 16),
                    SizedBox(width: 4),
                    Text('Изменить', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Полнофункциональное модальное окно редактирования связанного товара
class _ProductEditorSheet extends StatefulWidget {
  final Product product;
  final ValueChanged<Product> onProductUpdated;

  const _ProductEditorSheet({required this.product, required this.onProductUpdated});

  @override
  State<_ProductEditorSheet> createState() => _ProductEditorSheetState();
}

class _ProductEditorSheetState extends State<_ProductEditorSheet> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();

  late TextEditingController _nameCtrl;
  late TextEditingController _barcodeCtrl;
  late TextEditingController _priceCtrl;
  late TextEditingController _costPriceCtrl;
  late TextEditingController _wholesalePriceCtrl;
  late TextEditingController _categoryCtrl;
  late String _selectedUnit;

  File? _currentImageFile;
  int _rotationTurns = 0;
  bool _isSaving = false;
  String? _compressionInfo;

  final List<String> _commonUnits = ['шт', 'кг', 'л', 'уп', 'пач', 'кор', 'бутыл'];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.product.name);
    _barcodeCtrl = TextEditingController(text: widget.product.barcode ?? '');
    _priceCtrl = TextEditingController(text: widget.product.price.toStringAsFixed(2));
    _costPriceCtrl = TextEditingController(
      text: widget.product.costPrice > 0 ? widget.product.costPrice.toStringAsFixed(2) : '',
    );
    _wholesalePriceCtrl = TextEditingController(
      text: (widget.product.wholesalePrice != null && widget.product.wholesalePrice! > 0)
          ? widget.product.wholesalePrice!.toStringAsFixed(2)
          : '',
    );
    _categoryCtrl = TextEditingController(text: widget.product.category ?? 'Продукты');
    _selectedUnit = widget.product.unit.isNotEmpty ? widget.product.unit : 'шт';

    if (widget.product.localImagePath != null && File(widget.product.localImagePath!).existsSync()) {
      _currentImageFile = File(widget.product.localImagePath!);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    _priceCtrl.dispose();
    _costPriceCtrl.dispose();
    _wholesalePriceCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  // Сканирование нового штрихкода для товара камерой
  Future<void> _scanBarcode() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      setState(() {
        _barcodeCtrl.text = scanned;
      });
      HapticFeedback.selectionClick();
    }
  }

  // Сжатие и сохранение фото в формате 1:1 (квадрат) до <= 40 КБ
  Future<void> _pickAndCompressImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );

      if (picked != null) {
        final originalFile = File(picked.path);
        final originalSize = await originalFile.length();

        final appDir = await getApplicationDocumentsDirectory();
        final fileName = 'prod_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final targetPath = '${appDir.path}/$fileName';

        // Обрезаем до строгого квадрата 1:1 и сжимаем строго до 40 КБ
        final savedFile = await ImageUtils.cropToSquareAndCompress(
          originalFile,
          targetPath,
          maxSize: 550,
          quality: 80,
          maxKb: 40,
        );
        final compressedSize = await savedFile.length();

        final origMb = (originalSize / (1024 * 1024)).toStringAsFixed(1);
        final compKb = (compressedSize / 1024).toStringAsFixed(0);

        setState(() {
          _currentImageFile = savedFile;
          _rotationTurns = 0;
          _compressionInfo = 'Формат 1:1 (квадрат) • ${origMb} МБ ➔ ${compKb} КБ (≤ 40 КБ)';
        });

        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      TopNotification.showError(context, 'Ошибка съёмки/выбора фото: $e');
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

  // Сохранение всех изменений товара и отправка на сервер gusar.tj
  Future<void> _saveAllChanges() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      TopNotification.showError(context, 'Укажите название товара');
      return;
    }

    final price = double.tryParse(_priceCtrl.text.replaceAll(',', '.').trim());
    if (price == null || price < 0) {
      TopNotification.showError(context, 'Укажите корректную розничную цену');
      return;
    }

    final costPrice = double.tryParse(_costPriceCtrl.text.replaceAll(',', '.').trim()) ?? 0.0;
    final wholesalePrice = double.tryParse(_wholesalePriceCtrl.text.replaceAll(',', '.').trim());
    final barcode = _barcodeCtrl.text.trim().isNotEmpty ? _barcodeCtrl.text.trim() : null;

    setState(() => _isSaving = true);

    try {
      Product updated = widget.product.copyWith(
        name: name,
        price: price,
        costPrice: costPrice,
        wholesalePrice: wholesalePrice,
        barcode: barcode,
        unit: _selectedUnit,
        category: _categoryCtrl.text.trim().isNotEmpty ? _categoryCtrl.text.trim() : 'Продукты',
      );

      // 1. Отправляем обновленные реквизиты на сервер (PUT /api/products/:id)
      final res = await _api.updateProduct(updated);
      if (res != null) {
        updated = res;
      }

      // 2. Если фото было выбрано/изменено/повернуто, загружаем его на сервер (PATCH /api/products/:id/image)
      if (_currentImageFile != null) {
        File fileToUpload = _currentImageFile!;
        if (_rotationTurns != 0) {
          final appDir = await getApplicationDocumentsDirectory();
          final rotName = 'rot_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          fileToUpload = await ImageUtils.cropToSquareAndCompress(
            _currentImageFile!,
            '${appDir.path}/$rotName',
            quarterTurns: _rotationTurns,
            maxSize: 550,
            quality: 80,
            maxKb: 40,
          );
        }

        final photoUpdated = await _api.uploadProductImage(
          widget.product.id,
          fileToUpload.path,
        );
        if (photoUpdated != null) {
          updated = photoUpdated;
        }
      }

      setState(() => _isSaving = false);

      if (mounted) {
        TopNotification.showSuccess(context, 'Товар "$name" успешно обновлен в gusar.tj!');
        widget.onProductUpdated(updated);
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        TopNotification.showError(context, 'Ошибка сохранения: $e');
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Шапка модального окна
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.edit_note_rounded, color: Color(0xFF38BDF8), size: 22),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Редактирование товара', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('Прямая синхронизация с базой gusar.tj', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 1. Фотография товара
              Container(
                width: double.infinity,
                height: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _currentImageFile != null
                      ? Stack(
                          alignment: Alignment.center,
                          children: [
                            RotatedBox(
                              quarterTurns: _rotationTurns,
                              child: Image.file(_currentImageFile!, fit: BoxFit.contain, width: double.infinity, height: 160),
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
                          ? ProductImageWidget(
                              imageUrl: widget.product.imageUrl,
                              localImagePath: widget.product.localImagePath,
                              fit: BoxFit.contain,
                              placeholder: const Center(
                                child: Text('Фотография не привязана', style: TextStyle(color: Colors.white38, fontSize: 12)),
                              ),
                            )
                          : const Center(
                              child: Text('Фотография не привязана', style: TextStyle(color: Colors.white38, fontSize: 12)),
                            ),
                ),
              ),

              if (_compressionInfo != null) ...[
                const SizedBox(height: 6),
                Text(_compressionInfo!, style: const TextStyle(color: Color(0xFF34D399), fontSize: 11)),
              ],

              const SizedBox(height: 10),

              // Кнопки работы со снимком
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF10B981)),
                        foregroundColor: const Color(0xFF10B981),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _pickAndCompressImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_rounded, size: 16),
                      label: const Text('Камера', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        foregroundColor: const Color(0xFF38BDF8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _pickAndCompressImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_rounded, size: 16),
                      label: const Text('Галерея', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  if (_currentImageFile != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                      tooltip: 'Удалить фото',
                      onPressed: _removePhoto,
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 14),

              // 2. Название товара
              const Text('Название товара *', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),

              const SizedBox(height: 12),

              // 3. Штрихкод (со сканером)
              const Text('Штрихкод', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _barcodeCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981)),
                    tooltip: 'Сканировать штрихкод камерой',
                    onPressed: _scanBarcode,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 4. Розничная цена и себестоимость
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Розничная цена (TJS) *', style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _priceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Себестоимость (закуп)', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _costPriceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 5. Оптовая цена и единица измерения
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Оптовая цена (TJS)', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _wholesalePriceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Единица изм.', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _commonUnits.contains(_selectedUnit) ? _selectedUnit : _commonUnits.first,
                              dropdownColor: const Color(0xFF1E293B),
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              items: _commonUnits
                                  .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) setState(() => _selectedUnit = val);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 6. Категория товара
              const Text('Категория', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),

              const SizedBox(height: 18),

              // Кнопка сохранения
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isSaving ? null : _saveAllChanges,
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.save_rounded, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text('Сохранить изменения в gusar.tj', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
