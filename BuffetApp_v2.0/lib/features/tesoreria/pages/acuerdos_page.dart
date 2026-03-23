import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../layout/erp_layout.dart';
import '../../../widgets/summary_card.dart';
import '../../../widgets/status_badge.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/skeleton_loader.dart';

import '../../../features/shared/services/acuerdos_service.dart';
import '../widgets/ayuda_tesoreria_dialog.dart';
import '../../../features/shared/format.dart';
import '../../../data/dao/db.dart';
import 'crear_acuerdo_page.dart';
import 'detalle_acuerdo_page.dart';
import 'nuevo_acuerdo_grupal_page.dart';

/// Página principal de gestión de acuerdos financieros.
///
/// Muestra KPIs, filtros tipo tabs, tabla estilizada y acciones.
/// Los acuerdos son reglas/contratos que generan compromisos automáticamente.
class AcuerdosPage extends StatefulWidget {
  const AcuerdosPage({super.key});

  @override
  State<AcuerdosPage> createState() => _AcuerdosPageState();
}

class _AcuerdosPageState extends State<AcuerdosPage> {
  List<Map<String, dynamic>> _acuerdos = [];
  List<Map<String, dynamic>> _entidadesPlantel = [];
  bool _isLoading = true;

  // Filtros
  int? _entidadPlantelId;
  String? _tipoFiltro; // 'INGRESO', 'EGRESO', null = todos
  bool? _activoFiltro; // true = activos, false = finalizados, null = todos
  String? _origenFiltro; // 'MANUAL', 'GRUPAL', null = todos
  String _nombreFiltro = '';
  late final TextEditingController _searchController;

  // Vista
  bool _vistaTabla = true; // false = tarjetas, true = tabla

  // Ordenamiento de la tabla
  String? _sortColumn;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _cargarDatos();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    setState(() => _isLoading = true);

    try {
      final db = await AppDatabase.instance();

      // Solo cargar entidades que tienen al menos un acuerdo activo
      final entidadesRaw = await db.rawQuery(
        'SELECT DISTINCT ep.* FROM entidades_plantel ep '
        'INNER JOIN acuerdos a ON a.entidad_plantel_id = ep.id '
        'WHERE ep.estado_activo = 1 AND a.eliminado = 0 '
        'ORDER BY ep.nombre',
      );
      final entidades = entidadesRaw.map((e) => Map<String, dynamic>.from(e)).toList();

      List<Map<String, dynamic>> acuerdosRaw;

      if (_origenFiltro != null) {
        final soloGrupal = _origenFiltro == 'GRUPAL';
        acuerdosRaw = await AcuerdosService.listarAcuerdos(
          entidadPlantelId: _entidadPlantelId,
          tipo: _tipoFiltro,
          soloActivos: _activoFiltro,
        );
        acuerdosRaw = acuerdosRaw.where((a) {
          final origenGrupal = (a['origen_grupal'] as int?) == 1;
          return origenGrupal == soloGrupal;
        }).toList();
      } else {
        acuerdosRaw = await AcuerdosService.listarAcuerdos(
          entidadPlantelId: _entidadPlantelId,
          tipo: _tipoFiltro,
          soloActivos: _activoFiltro,
        );
      }

      final acuerdos =
          acuerdosRaw.map((a) => Map<String, dynamic>.from(a)).toList();

      for (final acuerdo in acuerdos) {
        final entidadId = acuerdo['entidad_plantel_id'] as int?;

        if (entidadId != null) {
          final entidad = entidades.firstWhere(
            (e) => e['id'] == entidadId,
            orElse: () => {'nombre': 'Desconocido'},
          );
          acuerdo['_entidad_nombre'] = entidad['nombre'];
        }

        final stats = await AcuerdosService.obtenerEstadisticasAcuerdo(
            acuerdo['id'] as int);
        acuerdo['_stats'] = stats;
      }

      setState(() {
        _acuerdos = acuerdos;
        _entidadesPlantel = entidades;
        _isLoading = false;
      });
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_page.cargar_datos',
        error: e.toString(),
        stackTrace: stack,
      );

      setState(() {
        _acuerdos = [];
        _entidadesPlantel = [];
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Error al cargar acuerdos. Por favor, intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  void _limpiarFiltros() {
    setState(() {
      _entidadPlantelId = null;
      _tipoFiltro = null;
      _activoFiltro = null;
      _origenFiltro = null;
      _nombreFiltro = '';
      _searchController.clear();
    });
    _cargarDatos();
  }

  Future<void> _finalizarAcuerdo(int id, String nombre) async {
    try {
      final db = await AppDatabase.instance();

      final compromisosAsociados = await db.query(
        'compromisos',
        columns: ['id'],
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [id],
      );

      final compromisoIds =
          compromisosAsociados.map((c) => c['id'] as int).toList();

      final cuotasEsperadas = compromisoIds.isEmpty
          ? <Map<String, dynamic>>[]
          : await db.query(
              'compromiso_cuotas',
              where:
                  'compromiso_id IN (${List.filled(compromisoIds.length, '?').join(',')}) AND estado = ?',
              whereArgs: [...compromisoIds, 'ESPERADO'],
            );

      String? accion;
      if (cuotasEsperadas.isNotEmpty) {
        accion = await showDialog<String>(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: context.appColors.bgSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
              side: BorderSide(color: context.appColors.border),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.advertencia.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                          ),
                          child: const Icon(Icons.warning_amber_rounded,
                              color: AppColors.advertencia, size: 22),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Text('Finalizar Acuerdo', style: AppText.titleLg),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '¿Desea finalizar el acuerdo "$nombre"?',
                      style: AppText.bodyLg.copyWith(color: context.appColors.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: context.appColors.advertenciaDim.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                        border: Border.all(color: AppColors.advertencia.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline,
                              color: AppColors.advertencia, size: 18),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              '${cuotasEsperadas.length} cuota${cuotasEsperadas.length > 1 ? 's' : ''} en estado ESPERADO',
                              style: AppText.bodyMd.copyWith(
                                  color: AppColors.advertenciaLight),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: TextButton.styleFrom(
                            foregroundColor: context.appColors.textMuted,
                          ),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, 'SOLO_FINALIZAR'),
                          style: TextButton.styleFrom(
                            foregroundColor: context.appColors.textSecondary,
                          ),
                          child: const Text('Solo finalizar'),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        FilledButton(
                          onPressed: () =>
                              Navigator.pop(ctx, 'FINALIZAR_Y_CANCELAR'),
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.advertencia),
                          child: const Text('Finalizar y cancelar cuotas'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      } else {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: context.appColors.bgSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
              side: BorderSide(color: context.appColors.border),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Finalizar Acuerdo', style: AppText.titleLg),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      '¿Finalizar el acuerdo "$nombre"?\nEsto marcará el acuerdo como inactivo.',
                      style: AppText.bodyMd,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: TextButton.styleFrom(
                              foregroundColor: context.appColors.textMuted),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.advertencia),
                          child: const Text('Finalizar'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        accion = confirm == true ? 'SOLO_FINALIZAR' : null;
      }

      if (accion == null) return;

      await AcuerdosService.finalizarAcuerdo(id);

      if (accion == 'FINALIZAR_Y_CANCELAR') {
        int cancelados = 0;

        for (final cuota in cuotasEsperadas) {
          final cuotaId = cuota['id'] as int;

          try {
            await db.update(
              'compromiso_cuotas',
              {
                'estado': 'CANCELADO',
                'observacion_cancelacion':
                    'Cancelada por finalización de acuerdo',
                'updated_ts': DateTime.now().millisecondsSinceEpoch,
              },
              where: 'id = ?',
              whereArgs: [cuotaId],
            );
            cancelados++;
          } catch (e) {
            await AppDatabase.logLocalError(
              scope: 'acuerdos_page.cancelar_cuotas',
              error: e.toString(),
              payload: {'cuota_id': cuotaId},
            );
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Acuerdo finalizado. $cancelados cuota${cancelados > 1 ? 's' : ''} cancelada${cancelados > 1 ? 's' : ''}.')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Acuerdo finalizado correctamente')),
          );
        }
      }

      _cargarDatos();
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_page.finalizar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No se pudo finalizar el acuerdo. Intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  // ─── KPIs derivados ─────────────────────────────────────────────────────────
  double get _totalIngresoMensual {
    double sum = 0;
    for (final a in _acuerdos) {
      if ((a['tipo']?.toString() ?? '') == 'INGRESO' &&
          (a['activo'] as int?) == 1) {
        sum += (a['monto_periodico'] as num?)?.toDouble() ?? 0;
      }
    }
    return sum;
  }

  double get _totalEgresoMensual {
    double sum = 0;
    for (final a in _acuerdos) {
      if ((a['tipo']?.toString() ?? '') == 'EGRESO' &&
          (a['activo'] as int?) == 1) {
        sum += (a['monto_periodico'] as num?)?.toDouble() ?? 0;
      }
    }
    return sum;
  }

  int get _countActivos =>
      _acuerdos.where((a) => (a['activo'] as int?) == 1).length;

  int get _countIngresos => _acuerdos.where((a) =>
      (a['tipo']?.toString() ?? '') == 'INGRESO' &&
      (a['activo'] as int?) == 1).length;

  int get _countEgresos => _acuerdos.where((a) =>
      (a['tipo']?.toString() ?? '') == 'EGRESO' &&
      (a['activo'] as int?) == 1).length;

  // ─── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.of(context).size.width >= AppSpacing.breakpointTablet;

    return ErpLayout(
      currentRoute: '/acuerdos',
      title: 'Acuerdos',
      actions: [
        IconButton(
          icon: const Icon(Icons.help_outline),
          tooltip: 'Ayuda: Acuerdos vs Compromisos',
          onPressed: () => AyudaTesoreriaDialog.show(context),
        ),
        IconButton(
          icon: Icon(_vistaTabla ? Icons.view_list : Icons.table_chart),
          tooltip: _vistaTabla ? 'Vista tarjetas' : 'Vista tabla',
          onPressed: () => setState(() => _vistaTabla = !_vistaTabla),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refrescar',
          onPressed: _cargarDatos,
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
              onPressed: _mostrarMenuCreacion,
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.textPrimary,
              icon: const Icon(Icons.add),
              label: const Text('Nuevo Acuerdo'),
            ),
      body: _isLoading
          ? SkeletonLoader.cards(count: 3)
          : RefreshIndicator(
              onRefresh: _cargarDatos,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.contentPadding),
                children: [
                  if (isDesktop)
                    const SizedBox(height: AppSpacing.lg),

                  // KPIs
                  _buildKpis(isDesktop),
                  const SizedBox(height: AppSpacing.lg),

                  // Filtros
                  _buildFilterBar(),
                  const SizedBox(height: AppSpacing.lg),

                  // Contenido
                  _acuerdosOrdenados.isEmpty
                      ? _buildEmptyState()
                      : _vistaTabla
                          ? _buildStyledTable()
                          : _buildVistaTarjetas(),
                ],
              ),
            ),
    );
  }

  // ─── KPI CARDS ──────────────────────────────────────────────────────────────
  Widget _buildKpis(bool isDesktop) {
    final resultado = _totalIngresoMensual - _totalEgresoMensual;
    final resultadoColor =
        resultado >= 0 ? AppColors.ingreso : AppColors.egreso;

    final cards = [
      SummaryCard(
        title: 'INGRESO MENSUAL',
        value: Format.moneyNoDecimals(_totalIngresoMensual),
        icon: Icons.trending_up,
        color: AppColors.ingreso,
      ),
      SummaryCard(
        title: 'EGRESO MENSUAL',
        value: Format.moneyNoDecimals(_totalEgresoMensual),
        icon: Icons.trending_down,
        color: AppColors.egreso,
      ),
      SummaryCard(
        title: 'RESULTADO PROY.',
        value: Format.moneyNoDecimals(resultado),
        icon: resultado >= 0 ? Icons.thumb_up : Icons.thumb_down,
        color: resultadoColor,
      ),
      SummaryCard(
        title: 'ACTIVOS: $_countIngresos ing · $_countEgresos egr',
        value: '$_countActivos',
        icon: Icons.description_outlined,
        color: AppColors.info,
      ),
    ];

    if (isDesktop) {
      return Row(
        children: cards
            .map((c) => Expanded(
                child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: c)))
            .toList(),
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children:
          cards.map((c) => SizedBox(width: double.infinity, child: c)).toList(),
    );
  }

  // ─── FILTER BAR (tabs + dropdowns) ──────────────────────────────────────────
  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: AppDecorations.cardOf(context),
      child: Column(
        children: [
          // Tipo tabs
          Row(
            children: [
              _buildTabBtn('Todos', null),
              const SizedBox(width: AppSpacing.xs),
              _buildTabBtn('Ingresos', 'INGRESO'),
              const SizedBox(width: AppSpacing.xs),
              _buildTabBtn('Egresos', 'EGRESO'),
              const Spacer(),
              // Dropdown filtros adicionales
              _buildDropdownFilter<bool?>(
                value: _activoFiltro,
                hint: 'Estado',
                items: const {null: 'Todos', true: 'Activos', false: 'Finalizados'},
                onChanged: (v) {
                  setState(() => _activoFiltro = v);
                  _cargarDatos();
                },
              ),
              const SizedBox(width: AppSpacing.sm),
              _buildDropdownFilter<String?>(
                value: _origenFiltro,
                hint: 'Origen',
                items: const {null: 'Todos', 'MANUAL': 'Manual', 'GRUPAL': 'Grupal'},
                onChanged: (v) {
                  setState(() => _origenFiltro = v);
                  _cargarDatos();
                },
              ),
              if (_tieneFiltrosActivos()) ...[
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  icon: Icon(Icons.clear, size: 18,
                      color: context.appColors.textMuted),
                  tooltip: 'Limpiar filtros',
                  onPressed: _limpiarFiltros,
                ),
              ],
            ],
          ),
          // Segunda fila: búsqueda por nombre + entidad
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              // Búsqueda por nombre
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar por nombre...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                  onChanged: (val) {
                    setState(() => _nombreFiltro = val.trim());
                  },
                ),
              ),
              if (_entidadesPlantel.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.sm),
                _buildDropdownFilter<int?>(
                  value: _entidadPlantelId,
                  hint: 'Entidad',
                  items: {
                    null: 'Todas',
                    for (final e in _entidadesPlantel)
                      e['id'] as int: e['nombre'] as String,
                  },
                  onChanged: (v) {
                    setState(() => _entidadPlantelId = v);
                    _cargarDatos();
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabBtn(String label, String? tipoValue) {
    final active = _tipoFiltro == tipoValue;
    return GestureDetector(
      onTap: () {
        setState(() => _tipoFiltro = tipoValue);
        _cargarDatos();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: active ? context.appColors.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        ),
        child: Text(
          label,
          style: AppText.titleSm.copyWith(
            color: active ? context.appColors.textPrimary : context.appColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildDropdownFilter<T>({
    required T value,
    required String hint,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: AppDecorations.inputOf(context),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(hint, style: AppText.bodyMd),
          dropdownColor: context.appColors.bgElevated,
          style: AppText.bodyMd.copyWith(color: context.appColors.textPrimary),
          isDense: true,
          items: items.entries
              .map((e) => DropdownMenuItem<T>(
                    value: e.key,
                    child: Text(e.value),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v as T),
        ),
      ),
    );
  }

  bool _tieneFiltrosActivos() {
    return _entidadPlantelId != null ||
        _tipoFiltro != null ||
        _activoFiltro != null ||
        _origenFiltro != null ||
        _nombreFiltro.isNotEmpty;
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.description_outlined,
      title: _tieneFiltrosActivos()
          ? 'No hay acuerdos con los filtros aplicados'
          : 'No hay acuerdos registrados',
      subtitle: !_tieneFiltrosActivos()
          ? 'Creá tu primer acuerdo para comenzar'
          : null,
    );
  }

  // ─── STYLED TABLE ──────────────────────────────────────────────────────────
  Widget _buildStyledTable() {
    return Container(
      decoration: AppDecorations.cardOf(context),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: context.appColors.border)),
            ),
            child: Row(
              children: [
                _tableHeader('NOMBRE', flex: 3, sortKey: 'nombre'),
                _tableHeader('TIPO', flex: 1, sortKey: 'tipo'),
                _tableHeader('ENTIDAD', flex: 2, sortKey: '_entidad_nombre'),
                _tableHeader('MONTO', flex: 2, sortKey: '_monto_sort'),
                _tableHeader('MODALIDAD', flex: 1, sortKey: 'modalidad'),
                _tableHeader('FRECUENCIA', flex: 1, sortKey: 'frecuencia'),
                _tableHeader('PROGRESO', flex: 2),
                _tableHeader('ESTADO', flex: 1, sortKey: 'activo'),
                _tableHeader('', flex: 1), // acciones
              ],
            ),
          ),
          // Rows
          ..._acuerdosOrdenados.asMap().entries.map((entry) {
            try {
              return _buildStyledRow(entry.value, entry.key);
            } catch (e, stack) {
              AppDatabase.logLocalError(
                scope: 'acuerdos_page.render_fila_tabla',
                error: e.toString(),
                stackTrace: stack,
                payload: {'acuerdo_id': entry.value['id']},
              );
              return Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: AppColors.advertencia, size: 18),
                    const SizedBox(width: AppSpacing.sm),
                    Text('Error al mostrar acuerdo', style: AppText.bodyMd),
                  ],
                ),
              );
            }
          }),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> get _acuerdosOrdenados {
    var list = List<Map<String, dynamic>>.from(_acuerdos);

    // Filtro por nombre (en-memoria)
    if (_nombreFiltro.isNotEmpty) {
      final query = _nombreFiltro.toLowerCase();
      list = list.where((a) {
        final nombre = (a['nombre'] as String? ?? '').toLowerCase();
        return nombre.contains(query);
      }).toList();
    }
    if (_sortColumn != null) {
      list.sort((a, b) {
        dynamic va;
        dynamic vb;
        if (_sortColumn == '_monto_sort') {
          final modalidadA = a['modalidad']?.toString() ?? '';
          va = (modalidadA == 'MONTO_TOTAL_CUOTAS'
              ? (a['monto_total'] as num?)?.toDouble()
              : (a['monto_periodico'] as num?)?.toDouble()) ??
              0.0;
          final modalidadB = b['modalidad']?.toString() ?? '';
          vb = (modalidadB == 'MONTO_TOTAL_CUOTAS'
              ? (b['monto_total'] as num?)?.toDouble()
              : (b['monto_periodico'] as num?)?.toDouble()) ??
              0.0;
        } else {
          va = a[_sortColumn!];
          vb = b[_sortColumn!];
        }
        int cmp;
        if (va == null && vb == null) {
          cmp = 0;
        } else if (va == null) {
          cmp = -1;
        } else if (vb == null) {
          cmp = 1;
        } else if (va is num && vb is num) {
          cmp = va.compareTo(vb);
        } else {
          cmp = va.toString().toLowerCase().compareTo(vb.toString().toLowerCase());
        }
        return _sortAsc ? cmp : -cmp;
      });
    }
    return list;
  }

  Widget _tableHeader(String label, {int flex = 1, String? sortKey}) {
    final isActive = sortKey != null && _sortColumn == sortKey;
    return Expanded(
      flex: flex,
      child: sortKey == null
          ? Text(label, style: AppText.label)
          : GestureDetector(
              onTap: () {
                setState(() {
                  if (_sortColumn == sortKey) {
                    _sortAsc = !_sortAsc;
                  } else {
                    _sortColumn = sortKey;
                    _sortAsc = true;
                  }
                });
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: AppText.label),
                  const SizedBox(width: 4),
                  Icon(
                    isActive
                        ? (_sortAsc ? Icons.arrow_upward : Icons.arrow_downward)
                        : Icons.unfold_more,
                    size: 14,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStyledRow(Map<String, dynamic> acuerdo, int index) {
    final id = acuerdo['id'] as int;
    final nombre = acuerdo['nombre']?.toString() ?? 'Sin nombre';
    final tipo = acuerdo['tipo']?.toString() ?? 'EGRESO';
    final modalidad = acuerdo['modalidad']?.toString() ?? 'RECURRENTE';
    final frecuencia = acuerdo['frecuencia']?.toString() ?? '';
    final activo = (acuerdo['activo'] as int?) == 1;
    final origenGrupal = (acuerdo['origen_grupal'] as int?) == 1;
    final entidadNombre = acuerdo['_entidad_nombre']?.toString() ?? '-';
    final stats = acuerdo['_stats'] as Map<String, dynamic>?;

    final unidad = acuerdo['unidad']?.toString() ?? 'ARS';
    final montoDisplay = modalidad == 'MONTO_TOTAL_CUOTAS'
        ? (acuerdo['monto_total'] as num?)?.toDouble() ?? 0.0
        : (acuerdo['monto_periodico'] as num?)?.toDouble() ?? 0.0;
    final montoTexto = unidad == 'LTS'
        ? '${Format.numero(montoDisplay)} Lts'
        : Format.money(montoDisplay);

    final cuotasConfirmadas = stats?['cuotas_confirmadas'] as int? ?? 0;
    final cuotasEsperadas = stats?['cuotas_esperadas'] as int? ?? 0;
    final cuotasTotal = cuotasConfirmadas + cuotasEsperadas;
    final progreso = cuotasTotal > 0 ? cuotasConfirmadas / cuotasTotal : 0.0;
    final porciento = (progreso * 100).toInt();

    final esIngreso = tipo == 'INGRESO';
    final tipoColor = esIngreso ? AppColors.ingreso : AppColors.egreso;

    // Iniciales para avatar
    final iniciales = nombre.length >= 2
        ? nombre.substring(0, 2).toUpperCase()
        : nombre.toUpperCase();

    return InkWell(
      onTap: () => _verDetalle(id),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: context.appColors.border.withValues(alpha: 0.5))),
        ),
        child: Row(
          children: [
            // Nombre con avatar
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: esIngreso
                          ? context.appColors.ingresoDim
                          : context.appColors.infoDim,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      iniciales,
                      style: AppText.label.copyWith(
                        color: esIngreso
                            ? AppColors.ingresoLight
                            : AppColors.infoLight,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nombre,
                          style: AppText.titleSm,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (origenGrupal)
                          Text('Grupal', style: AppText.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Tipo
            Expanded(
              flex: 1,
              child: StatusBadge(
                label: tipo,
                type: esIngreso ? StatusType.success : StatusType.danger,
              ),
            ),

            // Entidad
            Expanded(
              flex: 2,
              child: Text(
                entidadNombre,
                style: AppText.bodyMd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // Monto
            Expanded(
              flex: 2,
              child: Text(
                montoTexto,
                style: AppText.monoBold.copyWith(color: tipoColor),
              ),
            ),

            // Modalidad
            Expanded(
              flex: 1,
              child: Text(_modalidadLabel(modalidad), style: AppText.bodyMd),
            ),

            // Frecuencia
            Expanded(
              flex: 1,
              child: Text(_frecuenciaLabel(frecuencia), style: AppText.caption),
            ),

            // Progreso
            Expanded(
              flex: 2,
              child: cuotasTotal > 0
                  ? Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progreso,
                                  minHeight: 4,
                                  backgroundColor: context.appColors.bgElevated,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      tipoColor),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$cuotasConfirmadas/$cuotasTotal',
                                style: AppText.caption,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text('$porciento%', style: AppText.monoSm),
                      ],
                    )
                  : Text('-', style: AppText.bodyMd),
            ),

            // Estado
            Expanded(
              flex: 1,
              child: StatusBadge(
                label: activo ? 'Activo' : 'Finalizado',
                type: activo ? StatusType.success : StatusType.neutral,
              ),
            ),

            // Acciones
            Expanded(
              flex: 1,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _ghostButton('Ver', () => _verDetalle(id)),
                  if (activo) ...[
                    const SizedBox(width: AppSpacing.xs),
                    _ghostButton(
                        'Finalizar', () => _finalizarAcuerdo(id, nombre),
                        color: AppColors.advertencia),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ghostButton(String label, VoidCallback onTap, {Color? color}) {
    final c = color ?? AppColors.accent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        child: Text(
          label,
          style: AppText.labelMd.copyWith(color: c),
        ),
      ),
    );
  }

  // ─── CARD VIEW ──────────────────────────────────────────────────────────────
  Widget _buildVistaTarjetas() {
    return Column(
      children: _acuerdosOrdenados.asMap().entries.map((entry) {
        try {
          return _buildTarjetaAcuerdo(entry.value);
        } catch (e, stack) {
          AppDatabase.logLocalError(
            scope: 'acuerdos_page.render_tarjeta',
            error: e.toString(),
            stackTrace: stack,
            payload: {'index': entry.key},
          );
          return Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: AppDecorations.cardOf(context),
            child: Row(
              children: [
                const Icon(Icons.warning, color: AppColors.advertencia, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Text('Error al mostrar acuerdo', style: AppText.bodyMd),
              ],
            ),
          );
        }
      }).toList(),
    );
  }

  Widget _buildTarjetaAcuerdo(Map<String, dynamic> acuerdo) {
    final id = acuerdo['id'] as int;
    final nombre = acuerdo['nombre']?.toString() ?? 'Sin nombre';
    final tipo = acuerdo['tipo']?.toString() ?? 'EGRESO';
    final modalidad = acuerdo['modalidad']?.toString() ?? 'RECURRENTE';
    final activo = (acuerdo['activo'] as int?) == 1;
    final origenGrupal = (acuerdo['origen_grupal'] as int?) == 1;
    final unidadNombre = acuerdo['_unidad_nombre']?.toString() ?? 'Desconocida';
    final entidadNombre = acuerdo['_entidad_nombre']?.toString();
    final stats = acuerdo['_stats'] as Map<String, dynamic>?;

    final unidad = acuerdo['unidad']?.toString() ?? 'ARS';
    final montoDisplay = modalidad == 'MONTO_TOTAL_CUOTAS'
        ? (acuerdo['monto_total'] as num?)?.toDouble() ?? 0.0
        : (acuerdo['monto_periodico'] as num?)?.toDouble() ?? 0.0;
    final montoTexto = unidad == 'LTS'
        ? '${Format.numero(montoDisplay)} Lts'
        : Format.money(montoDisplay);

    final cuotasConfirmadas = stats?['cuotas_confirmadas'] as int? ?? 0;
    final cuotasEsperadas = stats?['cuotas_esperadas'] as int? ?? 0;
    final cuotasTotal = cuotasConfirmadas + cuotasEsperadas;
    final progreso = cuotasTotal > 0 ? cuotasConfirmadas / cuotasTotal : 0.0;

    final esIngreso = tipo == 'INGRESO';
    final tipoColor = esIngreso ? AppColors.ingreso : AppColors.egreso;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: InkWell(
        onTap: () => _verDetalle(id),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: AppDecorations.cardOf(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Avatar
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: esIngreso
                          ? context.appColors.ingresoDim
                          : context.appColors.infoDim,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      esIngreso ? Icons.trending_up : Icons.trending_down,
                      color: esIngreso
                          ? AppColors.ingresoLight
                          : AppColors.infoLight,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(nombre, style: AppText.titleMd),
                        const SizedBox(height: 2),
                        Text(
                          '$unidadNombre${entidadNombre != null ? ' · $entidadNombre' : ''}',
                          style: AppText.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(
                    label: tipo,
                    type: esIngreso ? StatusType.success : StatusType.danger,
                  ),
                  if (origenGrupal) ...[
                    const SizedBox(width: AppSpacing.xs),
                    StatusBadge(
                        label: 'Grupal', type: StatusType.info),
                  ],
                  if (!activo) ...[
                    const SizedBox(width: AppSpacing.xs),
                    const StatusBadge(
                        label: 'Finalizado', type: StatusType.neutral),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.lg),

              // Monto + Modalidad
              Row(
                children: [
                  Text(
                    montoTexto,
                    style: AppText.kpiSm.copyWith(color: tipoColor),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.appColors.bgElevated,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: Text(_modalidadLabel(modalidad),
                        style: AppText.caption),
                  ),
                ],
              ),

              // Progreso
              if (cuotasTotal > 0) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progreso,
                          minHeight: 4,
                          backgroundColor: context.appColors.bgElevated,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(tipoColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      '$cuotasConfirmadas de $cuotasTotal cuotas',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ],

              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (activo)
                    _ghostButton(
                        'Finalizar', () => _finalizarAcuerdo(id, nombre),
                        color: AppColors.advertencia),
                  const SizedBox(width: AppSpacing.sm),
                  _ghostButton('Ver Detalle', () => _verDetalle(id)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── CREATION MODAL ─────────────────────────────────────────────────────────
  Future<void> _mostrarMenuCreacion() async {
    final opcion = await showDialog<String>(
      context: context,
      barrierColor: context.appColors.bgOverlay,
      builder: (ctx) => Dialog(
        backgroundColor: context.appColors.bgSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
          side: BorderSide(color: context.appColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Crear Acuerdo', style: AppText.titleLg),
                const SizedBox(height: AppSpacing.xs),
                Text('Seleccioná el tipo de acuerdo a crear',
                    style: AppText.bodyMd),
                const SizedBox(height: AppSpacing.xl),

                // Individual
                _buildCreationOption(
                  ctx: ctx,
                  icon: Icons.person,
                  color: AppColors.accent,
                  title: 'Individual',
                  subtitle: 'Para un solo jugador/DT',
                  value: 'INDIVIDUAL',
                ),
                const SizedBox(height: AppSpacing.md),

                // Grupal
                _buildCreationOption(
                  ctx: ctx,
                  icon: Icons.group,
                  color: AppColors.info,
                  title: 'Grupal',
                  subtitle: 'Para múltiples jugadores',
                  value: 'GRUPAL',
                ),

                const SizedBox(height: AppSpacing.xl),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                        foregroundColor: context.appColors.textMuted),
                    child: const Text('Cancelar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (opcion == 'INDIVIDUAL') {
      _crearNuevoAcuerdo();
    } else if (opcion == 'GRUPAL') {
      _crearAcuerdoGrupal();
    }
  }

  Widget _buildCreationOption({
    required BuildContext ctx,
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String value,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: context.appColors.bgBase,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: context.appColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.titleSm),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: context.appColors.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  // ─── NAVIGATION HELPERS ─────────────────────────────────────────────────────
  Future<void> _verDetalle(int id) async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => DetalleAcuerdoPage(acuerdoId: id),
      ),
    );
    if (resultado == true) {
      _cargarDatos();
    }
  }

  Future<void> _crearAcuerdoGrupal() async {
    final resultado = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            NuevoAcuerdoGrupalPage(unidadGestionId: 1),
      ),
    );

    if (resultado != null) {
      _cargarDatos();
    }
  }

  void _crearNuevoAcuerdo() async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => const CrearAcuerdoPage(),
      ),
    );

    if (resultado == true) {
      _cargarDatos();
    }
  }

  String _modalidadLabel(String modalidad) {
    switch (modalidad) {
      case 'MONTO_TOTAL_CUOTAS':
        return 'Cuotas';
      case 'RECURRENTE':
        return 'Recurrente';
      default:
        return modalidad;
    }
  }

  String _frecuenciaLabel(String frecuencia) {
    switch (frecuencia.toUpperCase()) {
      case 'MENSUAL':
        return 'Mensual';
      case 'SEMANAL':
        return 'Semanal';
      case 'QUINCENAL':
        return 'Quincenal';
      case 'DIARIO':
        return 'Diario';
      case 'ANUAL':
        return 'Anual';
      default:
        return frecuencia.isNotEmpty ? frecuencia : '—';
    }
  }
}
