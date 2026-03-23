import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/dao/db.dart';
import '../../../layout/erp_layout.dart';
import '../../../widgets/summary_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/format.dart';
import '../services/adhesiones_service.dart';
import 'confirmar_movimiento_page.dart';
import 'crear_acuerdo_page.dart';
import 'importar_adhesiones_page.dart';

/// Pantalla de seguimiento de Adhesiones (aportes de adherentes).
///
/// Muestra una tabla pivot con:
/// - Filas: adherentes (acuerdos con es_adhesion=1, tipo INGRESO)
/// - Columnas: meses Ene–Dic
/// - Celdas: estado de pago (pagado, parcial, pendiente, sin cuota)
///
/// Tabs: uno por cada subcategoría de ADHE que tenga datos cargados.
class AdhesionesPage extends StatefulWidget {
  const AdhesionesPage({super.key});

  @override
  State<AdhesionesPage> createState() => _AdhesionesPageState();
}

class _AdhesionesPageState extends State<AdhesionesPage>
    with TickerProviderStateMixin {
  final _service = AdhesionesService.instance;

  late TabController _tabController;
  int _anio = DateTime.now().year;
  bool _isLoading = true;

  // Subcategorías con datos + adherentes por subcategoría
  List<Map<String, dynamic>> _subcategorias = [];
  Map<int, List<Map<String, dynamic>>> _adherentesPorSubcat = {};

  // Color por índice de tab
  static const _tabColors = [
    Color(0xFF3b82f6), // azul
    Color(0xFFf59e0b), // ámbar
    Color(0xFF10b981), // verde
    Color(0xFF8b5cf6), // violeta
    Color(0xFFef4444), // rojo
  ];

  Color get _colorTab {
    if (_subcategorias.isEmpty) return _tabColors[0];
    final idx = _tabController.index.clamp(0, _tabColors.length - 1);
    return _tabColors[idx];
  }

  // Filtros
  String _busqueda = '';
  String _filtroChip = 'todos'; // todos | con_deuda | al_dia | sin_cuota

  static const _meses = [
    'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
    'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _cargarDatos();
  }

  void _rebuildTabController(int length) {
    final newLength = length < 1 ? 1 : length;
    if (_tabController.length != newLength) {
      _tabController.dispose();
      _tabController = TabController(length: newLength, vsync: this);
      _tabController.addListener(() {
        if (!_tabController.indexIsChanging) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    setState(() => _isLoading = true);
    try {
      final subcats = await _service.obtenerSubcategoriasConDatos();

      final Map<int, List<Map<String, dynamic>>> porSubcat = {};
      for (final subcat in subcats) {
        final id = subcat['id'] as int;
        porSubcat[id] = await _service.obtenerAdherentesPorSubcategoria(
          anio: _anio,
          subcategoriaId: id,
        );
      }

      if (mounted) {
        _rebuildTabController(subcats.length);
        setState(() {
          _subcategorias = subcats;
          _adherentesPorSubcat = porSubcat;
          _isLoading = false;
        });
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_page.cargar_datos',
        error: e.toString(),
        stackTrace: stack,
      );
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudieron cargar las adhesiones'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Muestra el diálogo para elegir entre agregar una adhesión individual
  /// o realizar una carga masiva desde un archivo Excel.
  Future<void> _mostrarMenuAgregarAdhesion() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Agregar Adhesión'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx);
              _irACrearAcuerdoIndividual();
            },
            child: const ListTile(
              leading: Icon(Icons.person_add_outlined),
              title: Text('Individual'),
              subtitle: Text('Agregar un acuerdo de forma manual'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx);
              _irACargaMasiva();
            },
            child: const ListTile(
              leading: Icon(Icons.upload_file_outlined),
              title: Text('Carga masiva'),
              subtitle: Text('Importar múltiples acuerdos desde un archivo Excel'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _irACrearAcuerdoIndividual() async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CrearAcuerdoPage()),
    );
    if (resultado == true && mounted) {
      _cargarDatos();
    }
  }

  Future<void> _irACargaMasiva() async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ImportarAdhesionesPage()),
    );
    if (resultado == true && mounted) {
      _cargarDatos();
    }
  }

  /// Adherentes del tab activo, sin filtros (para KPIs).
  List<Map<String, dynamic>> get _adherentesTabActual {
    if (_subcategorias.isEmpty) return [];
    final idx = _tabController.index.clamp(0, _subcategorias.length - 1);
    final subcatId = _subcategorias[idx]['id'] as int;
    return _adherentesPorSubcat[subcatId] ?? [];
  }

  /// Adherentes del tab activo con filtros de búsqueda/chip aplicados.
  List<Map<String, dynamic>> get _adherentesActivos =>
      _aplicarFiltros(_adherentesTabActual);

  List<Map<String, dynamic>> _aplicarFiltros(List<Map<String, dynamic>> lista) {
    var resultado = lista;

    // Filtro búsqueda
    if (_busqueda.isNotEmpty) {
      final query = _busqueda.toLowerCase();
      resultado = resultado.where((a) {
        final nombre = (a['nombre'] as String? ?? '').toLowerCase();
        final entidad = (a['entidad_nombre'] as String? ?? '').toLowerCase();
        return nombre.contains(query) || entidad.contains(query);
      }).toList();
    }

    // Filtro chip
    final ahora = DateTime.now();
    final mesActual = ahora.year == _anio ? ahora.month : 12;

    if (_filtroChip == 'cancelados') {
      resultado = resultado
          .where((a) => (a['activo'] as int? ?? 1) == 0)
          .toList();
    } else if (_filtroChip == 'con_deuda') {
      resultado = resultado.where((a) {
        final cuotas = a['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
        // Un acuerdo cancelado/pausado con algún cobro registrado también aparece aquí
        for (int m = 1; m <= mesActual; m++) {
          final cuota = cuotas[m];
          if (cuota == null || cuota['estado'] != 'CONFIRMADO') return true;
        }
        return false;
      }).toList();
    } else if (_filtroChip == 'al_dia') {
      resultado = resultado.where((a) {
        final cuotas = a['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
        if (cuotas.isEmpty) return false;
        for (int m = 1; m <= mesActual; m++) {
          final cuota = cuotas[m];
          if (cuota == null || cuota['estado'] != 'CONFIRMADO') return false;
        }
        return true;
      }).toList();
    } else if (_filtroChip == 'sin_cuota') {
      resultado = resultado.where((a) {
        final cuotas = a['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
        return cuotas.isEmpty;
      }).toList();
    }

    return resultado;
  }

  @override
  Widget build(BuildContext context) {
    final colorTab = _colorTab;

    return ErpLayout(
      currentRoute: '/adhesiones',
      title: 'Adhesiones',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refrescar',
          onPressed: _cargarDatos,
        ),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: _mostrarMenuAgregarAdhesion,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Agregar Adhesión'),
          style: FilledButton.styleFrom(
            backgroundColor: colorTab,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
        const SizedBox(width: 8),
      ],
      body: _isLoading
          ? SkeletonLoader.cards(count: 3)
          : _subcategorias.isEmpty
              ? EmptyState(
                  icon: Icons.volunteer_activism,
                  title: 'No hay adhesiones registradas',
                  subtitle: 'Usá el botón "Agregar Adhesión" para crear un acuerdo',
                  action: TextButton.icon(
                    onPressed: _mostrarMenuAgregarAdhesion,
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar Adhesión'),
                  ),
                )
              : Column(
                  children: [
                    // Selector de año
                    _buildSelectorAnio(colorTab),

                    // Tabs dinámicos por subcategoría
                    _buildTabs(colorTab),

                    // KPIs
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.contentPadding),
                      child: _buildKPIs(colorTab),
                    ),

                    // Filtros
                    _buildFiltros(colorTab),
                    const Divider(height: 1),

                    // Tabla pivot
                    Expanded(
                      child: _adherentesActivos.isEmpty
                          ? const EmptyState(
                              icon: Icons.volunteer_activism,
                              title: 'No hay adherentes en esta categoría',
                              subtitle: 'Agregá un acuerdo de adhesión para verlo aquí',
                            )
                          : _buildTablaPivot(colorTab),
                    ),
                  ],
                ),
    );
  }

  // ─── SELECTOR DE AÑO ─────────────────────────────────────────────────────
  Widget _buildSelectorAnio(Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() => _anio--);
              _cargarDatos();
            },
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: Text(
              '$_anio',
              style: AppText.titleSm.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() => _anio++);
              _cargarDatos();
            },
          ),
        ],
      ),
    );
  }

  // ─── TABS ─────────────────────────────────────────────────────────────────
  Widget _buildTabs(Color color) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.appColors.bgElevated,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorColor: color,
        labelColor: color,
        unselectedLabelColor: context.appColors.textSecondary,
        indicatorSize: TabBarIndicatorSize.tab,
        isScrollable: _subcategorias.length > 3,
        tabs: _subcategorias.asMap().entries.map((entry) {
          final i = entry.key;
          final subcat = entry.value;
          final nombre = subcat['nombre']?.toString() ?? 'Sin nombre';
          final subcatId = subcat['id'] as int;
          final count = _adherentesPorSubcat[subcatId]?.length ?? 0;
          return Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_iconoSubcategoria(nombre), size: 18),
                const SizedBox(width: 8),
                Text('$nombre ($count)'),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  IconData _iconoSubcategoria(String nombre) {
    final n = nombre.toLowerCase();
    if (n.contains('combustible')) return Icons.local_gas_station;
    if (n.contains('infraestructura')) return Icons.construction;
    if (n.contains('publicidad') || n.contains('sponsor')) return Icons.campaign;
    if (n.contains('colaboracion') || n.contains('colaboración')) return Icons.handshake;
    if (n.contains('sueldo')) return Icons.people;
    return Icons.category;
  }

  // ─── KPIs ─────────────────────────────────────────────────────────────────
  Widget _buildKPIs(Color color) {
    final adherentes = _adherentesTabActual;
    final kpis = _service.calcularKPIs(adherentes: adherentes, anio: _anio);

    final prometido = kpis['prometido_anual'] as double? ?? 0.0;
    final cobrado = kpis['cobrado'] as double? ?? 0.0;
    final resta = kpis['resta_cobrar'] as double? ?? 0.0;
    final porciento = kpis['porcentaje_al_dia'] as double? ?? 0.0;

    final isDesktop =
        MediaQuery.of(context).size.width >= AppSpacing.breakpointTablet;

    final cards = [
      SummaryCard(
        title: 'Prometido anual',
        value: Format.money(prometido),
        icon: Icons.account_balance_wallet,
        color: color,
      ),
      SummaryCard(
        title: 'Cobrado al día',
        value: Format.money(cobrado),
        icon: Icons.check_circle,
        color: AppColors.ingreso,
      ),
      SummaryCard(
        title: 'Resta cobrar',
        value: Format.money(resta),
        icon: Icons.pending,
        color: AppColors.advertencia,
      ),
      SummaryCard(
        title: '% al día',
        value: '${porciento.toStringAsFixed(1)}%',
        icon: Icons.trending_up,
        color: porciento >= 80
            ? AppColors.ingreso
            : porciento >= 50
                ? AppColors.advertencia
                : AppColors.egreso,
      ),
    ];

    if (isDesktop) {
      return Row(
        children: cards.map((c) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: c,
          ),
        )).toList(),
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: cards.map((c) => SizedBox(width: 180, child: c)).toList(),
    );
  }

  // ─── FILTROS ──────────────────────────────────────────────────────────────
  Widget _buildFiltros(Color color) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Row(
        children: [
          // Búsqueda
          SizedBox(
            width: 220,
            height: 36,
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Buscar adherente...',
                prefixIcon: const Icon(Icons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  borderSide: BorderSide(color: colors.border),
                ),
              ),
              onChanged: (v) => setState(() => _busqueda = v),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // Chips
          _buildFilterChip('Todos', 'todos', color),
          _buildFilterChip('Con deuda', 'con_deuda', color),
          _buildFilterChip('Al día', 'al_dia', color),
          _buildFilterChip('Sin cuota', 'sin_cuota', color),
          _buildFilterChip('Cancelados', 'cancelados', const Color(0xFF6B7280)),
          const Spacer(),
          Text(
            '${_adherentesActivos.length} adherente${_adherentesActivos.length != 1 ? 's' : ''}',
            style: TextStyle(
              fontSize: 14,
              color: colors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, Color color) {
    final selected = _filtroChip == value;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        selectedColor: color.withValues(alpha: 0.2),
        checkmarkColor: color,
        onSelected: (_) => setState(() => _filtroChip = value),
      ),
    );
  }

  // ─── TABLA PIVOT ──────────────────────────────────────────────────────────
  Widget _buildTablaPivot(Color colorTab) {
    final adherentes = _adherentesActivos;
    final totalesMes = _service.calcularTotalesPorMes(adherentes);
    final ahora = DateTime.now();
    final mesActual = ahora.year == _anio ? ahora.month : 13; // 13 = todos futuros

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Container(
          decoration: AppDecorations.cardOf(context),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                _buildHeaderRow(colorTab),

                // Data rows
                ...adherentes.asMap().entries.map((entry) {
                  try {
                    return _buildAdherenteRow(
                        entry.value, entry.key, colorTab, mesActual);
                  } catch (e, stack) {
                    AppDatabase.logLocalError(
                      scope: 'adhesiones_page.render_fila',
                      error: e.toString(),
                      stackTrace: stack,
                      payload: {'acuerdo_id': entry.value['acuerdo_id']},
                    );
                    return Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Row(
                        children: [
                          Icon(Icons.warning,
                              color: AppColors.advertencia, size: 18),
                          const SizedBox(width: AppSpacing.sm),
                          Text('Error al mostrar adhesión',
                              style: AppText.bodyMd),
                        ],
                      ),
                    );
                  }
                }),

                // Total row
                _buildTotalRow(totalesMes, colorTab),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow(Color colorTab) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: context.appColors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text('ADHERENTE', style: AppText.label),
          ),
          SizedBox(
            width: 100,
            child: Text('PROMETIDO', style: AppText.label),
          ),
          ...List.generate(12, (i) => SizedBox(
            width: 80,
            child: Center(
              child: Text(
                _meses[i],
                style: AppText.label.copyWith(
                  color: (i + 1) <= (DateTime.now().year == _anio ? DateTime.now().month : 0)
                      ? context.appColors.textPrimary
                      : context.appColors.textSecondary,
                ),
              ),
            ),
          )),
          SizedBox(
            width: 100,
            child: Text('COBRADO', style: AppText.label),
          ),
          SizedBox(
            width: 100,
            child: Text('RESTA', style: AppText.label),
          ),
        ],
      ),
    );
  }

  Widget _buildAdherenteRow(
    Map<String, dynamic> adherente,
    int index,
    Color colorTab,
    int mesActual,
  ) {
    final nombre = adherente['nombre'] as String? ?? 'Sin nombre';
    final montoPeriodico = (adherente['monto_periodico'] as num?)?.toDouble() ?? 0.0;
    final unidad = adherente['unidad'] as String? ?? 'ARS';
    final cuotasMap = adherente['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
    final sinCuotas = cuotasMap.isEmpty;
    final esCancelado = (adherente['activo'] as int? ?? 1) == 0;

    // Calcular cobrado y resta para este adherente
    // Para LTS: sumar cantidad_litros; para ARS: sumar monto_real
    double cobrado = 0;
    for (final cuota in cuotasMap.values) {
      if (cuota['estado'] == 'CONFIRMADO') {
        if (unidad == 'LTS') {
          cobrado += (cuota['cantidad_litros'] as num?)?.toDouble()
              ?? (cuota['monto_esperado'] as num?)?.toDouble()
              ?? 0.0;
        } else {
          cobrado += (cuota['monto_real'] as num?)?.toDouble()
              ?? (cuota['monto_esperado'] as num?)?.toDouble()
              ?? 0.0;
        }
      }
    }
    // Prometido: para cancelados solo lo ya cobrado (no hay más deuda)
    final prometido = esCancelado ? cobrado : montoPeriodico * 12;
    final resta = prometido - cobrado;

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: esCancelado ? const Color(0xFFF3F4F6) : null,
        border: Border(
          left: esCancelado
              ? const BorderSide(color: Color(0xFF9CA3AF), width: 3)
              : BorderSide.none,
          bottom: BorderSide(
              color: context.appColors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          // Nombre + badge cancelado
          SizedBox(
            width: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  nombre,
                  style: esCancelado
                      ? AppText.bodyMd.copyWith(
                          color: const Color(0xFF6B7280),
                          decoration: TextDecoration.lineThrough,
                          decorationColor: const Color(0xFF9CA3AF),
                        )
                      : sinCuotas
                          ? AppText.bodyMd.copyWith(
                              fontStyle: FontStyle.italic,
                              color: AppColors.advertencia,
                            )
                          : AppText.titleSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (esCancelado)
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6B7280).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Cancelado',
                      style: TextStyle(
                        fontSize: 9,
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Prometido mensual
          SizedBox(
            width: 100,
            child: Text(
              esCancelado ? '—' : _formatearMonto(montoPeriodico, unidad),
              style: AppText.monoSm.copyWith(
                color: esCancelado ? const Color(0xFF9CA3AF) : null,
              ),
            ),
          ),

          // Celdas mes 1-12
          ...List.generate(12, (i) {
            final mes = i + 1;
            return _buildCelda(
              cuotasMap[mes],
              mes,
              mesActual,
              montoPeriodico,
              unidad,
              colorTab,
              adherente['acuerdo_id'] as int,
              adherente['tipo'] as String? ?? 'INGRESO',
              adherente['categoria'] as String? ?? '',
              esCancelado: esCancelado,
            );
          }),

          // Cobrado
          SizedBox(
            width: 100,
            child: Text(
              _formatearMonto(cobrado, unidad),
              style: AppText.monoBold.copyWith(
                color: esCancelado
                    ? const Color(0xFF6B7280)
                    : AppColors.ingreso,
              ),
            ),
          ),

          // Resta
          SizedBox(
            width: 100,
            child: Text(
              esCancelado ? '—' : _formatearMonto(resta, unidad),
              style: AppText.monoBold.copyWith(
                color: esCancelado
                    ? const Color(0xFF9CA3AF)
                    : resta > 0
                        ? AppColors.egreso
                        : AppColors.ingreso,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCelda(
    Map<String, dynamic>? cuota,
    int mes,
    int mesActual,
    double montoEsperado,
    String unidad,
    Color colorTab,
    int acuerdoId,
    String tipo,
    String categoria, {
    bool esCancelado = false,
  }) {
    Color bgColor;
    Color textColor;
    String texto;

    final yaConfirmado =
        cuota != null && (cuota['estado'] as String? ?? '') == 'CONFIRMADO';

    if (yaConfirmado) {
      // Pagado — ¿completo o parcial? (igual para activos y cancelados)
      final montoReal = (cuota!['monto_real'] as num?)?.toDouble();
      final cantLitros = (cuota['cantidad_litros'] as num?)?.toDouble();
      final montoEsp =
          (cuota['monto_esperado'] as num?)?.toDouble() ?? montoEsperado;
      // Para LTS: comparar litros pagados vs litros esperados
      // Para ARS: comparar monto_real vs monto_esperado
      final double pagoActual = unidad == 'LTS'
          ? (cantLitros ?? montoEsp)
          : (montoReal ?? montoEsp);
      if (pagoActual < montoEsp) {
        bgColor = const Color(0xFFFEF3C7); // amarillo claro
        textColor = const Color(0xFF92400E);
      } else {
        bgColor = const Color(0xFFD1FAE5); // verde claro
        textColor = const Color(0xFF065F46);
      }
      texto = _formatearMontoCorto(pagoActual, unidad);
    } else if (esCancelado) {
      // Mes sin cobrar de un acuerdo cancelado → gris neutro
      bgColor = const Color(0xFFE5E7EB);
      textColor = const Color(0xFF9CA3AF);
      texto = '—';
    } else if (cuota != null) {
      // Acuerdo activo con cuota no confirmada
      final estado = cuota['estado'] as String? ?? 'ESPERADO';
      if (mes < mesActual) {
        // Vencido sin pagar
        bgColor = const Color(0xFFFEE2E2); // rojo claro
        textColor = const Color(0xFF991B1B);
        texto = '✕';
      } else {
        // Futuro pendiente
        bgColor = context.appColors.bgElevated;
        textColor = context.appColors.textSecondary;
        texto = '—';
      }
    } else {
      if (mes < mesActual) {
        // Mes pasado sin cuota (acuerdo activo)
        bgColor = const Color(0xFFFEE2E2).withValues(alpha: 0.5);
        textColor = const Color(0xFF991B1B).withValues(alpha: 0.6);
        texto = '✕';
      } else {
        // Futuro sin cuota (acuerdo activo)
        bgColor = context.appColors.bgElevated.withValues(alpha: 0.5);
        textColor = context.appColors.textSecondary;
        texto = '—';
      }
    }

    return SizedBox(
      width: 80,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: InkWell(
          onTap: () => _confirmarPagoAdhesion(acuerdoId, mes, cuota, montoEsperado, unidad, tipo, categoria),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            alignment: Alignment.center,
            child: Text(
              texto,
              style: AppText.monoSm.copyWith(
                color: textColor,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTotalRow(Map<int, Map<String, double>> totalesMes, Color colorTab) {
    double totalCobrado = 0;
    double totalEsperado = 0;

    for (final t in totalesMes.values) {
      totalCobrado += t['cobrado'] ?? 0;
      totalEsperado += t['esperado'] ?? 0;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: colorTab.withValues(alpha: 0.05),
        border: Border(
            top: BorderSide(color: context.appColors.border, width: 2)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text('TOTAL', style: AppText.titleSm.copyWith(color: colorTab)),
          ),
          SizedBox(
            width: 100,
            child: Text('', style: AppText.monoSm),
          ),
          ...List.generate(12, (i) {
            final mes = i + 1;
            final cobradoMes = totalesMes[mes]?['cobrado'] ?? 0;
            return SizedBox(
              width: 80,
              child: Center(
                child: Text(
                  cobradoMes > 0 ? _formatearMontoCorto(cobradoMes, 'ARS') : '—',
                  style: AppText.monoBold.copyWith(
                    color: cobradoMes > 0 ? AppColors.ingreso : context.appColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            );
          }),
          SizedBox(
            width: 100,
            child: Text(
              Format.money(totalCobrado),
              style: AppText.monoBold.copyWith(color: AppColors.ingreso),
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              Format.money(totalEsperado - totalCobrado),
              style: AppText.monoBold.copyWith(
                color: (totalEsperado - totalCobrado) > 0
                    ? AppColors.egreso
                    : AppColors.ingreso,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── FLUJO DE PAGO ADHESIÓN ────────────────────────────────────────────────
  Future<void> _confirmarPagoAdhesion(
    int acuerdoId,
    int mes,
    Map<String, dynamic>? cuotaExistente,
    double montoEsperado,
    String unidad,
    String tipo,
    String categoria,
  ) async {
    final yaConfirmado = cuotaExistente != null &&
        cuotaExistente['estado'] == 'CONFIRMADO';

    // Si ya está confirmado, mostrar info solamente
    if (yaConfirmado) {
      final mesNombre = DateFormat.MMMM('es').format(DateTime(_anio, mes));
      final montoReal = (cuotaExistente['monto_real'] as num?)?.toDouble() ?? montoEsperado;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Pago registrado — $mesNombre $_anio'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF065F46), size: 18),
                    SizedBox(width: 8),
                    Text('Pago ya registrado', style: TextStyle(color: Color(0xFF065F46))),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Monto: ${unidad == "LTS" ? "${montoReal.toStringAsFixed(0)} litros" : Format.money(montoReal)}',
                style: AppText.titleSm,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      return;
    }

    // Obtener compromisoId: de la cuota existente o buscándolo por acuerdoId
    int? compromisoId;
    if (cuotaExistente != null && cuotaExistente['compromiso_id'] != null) {
      compromisoId = cuotaExistente['compromiso_id'] as int;
    } else {
      compromisoId = await _service.obtenerCompromisoIdDeAcuerdo(acuerdoId);
    }

    if (compromisoId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Este acuerdo no tiene compromiso asociado. Verificá que se haya generado correctamente.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final fechaVencimiento = DateTime(_anio, mes, 1);

    if (!mounted) return;

    final nroCuota = cuotaExistente != null
        ? (cuotaExistente['numero_cuota'] as int?)
        : null;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ConfirmarMovimientoPage(
          compromisoId: compromisoId!,
          fechaVencimiento: fechaVencimiento,
          montoSugerido: montoEsperado,
          tipo: tipo,
          categoria: categoria,
          numeroCuota: nroCuota,
          unidadAcuerdo: unidad,
        ),
      ),
    );

    if (result == true && mounted) {
      _cargarDatos();
    }
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────
  String _formatearMonto(double monto, String unidad) {
    if (unidad == 'LTS') {
      return '${monto.toStringAsFixed(0)} lts';
    }
    return Format.money(monto);
  }

  String _formatearMontoCorto(double monto, String unidad) {
    if (unidad == 'LTS') {
      return '${monto.toStringAsFixed(0)} lts';
    }
    // Formato corto para celdas: sin decimales si es entero
    if (monto >= 1000) {
      return '${(monto / 1000).toStringAsFixed(1)}k';
    }
    return monto.toStringAsFixed(0);
  }
}
