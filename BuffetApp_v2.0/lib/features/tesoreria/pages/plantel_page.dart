import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/dao/db.dart';
import '../../../features/shared/services/plantel_service.dart';
import '../../../layout/erp_layout.dart';
import '../../../widgets/app_header.dart';
import '../../../widgets/summary_card.dart';
import '../../../widgets/status_badge.dart';
import '../../shared/format.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/skeleton_loader.dart';
import 'detalle_jugador_page.dart';
import 'gestionar_jugadores_page.dart';

/// FASE 17.4: Pantalla resumen de la situación económica del plantel.
/// Vista de solo lectura que muestra el estado de pagos de jugadores/cuerpo técnico.
class PlantelPage extends StatefulWidget {
  const PlantelPage({Key? key}) : super(key: key);

  @override
  State<PlantelPage> createState() => _PlantelPageState();
}

class _PlantelPageState extends State<PlantelPage> {
  final _plantelSvc = PlantelService.instance;

  bool _cargando = true;
  String _filtroRol = 'TODOS';
  String _filtroEstado = 'ACTIVOS';
  bool _vistaTabla = true; // tabla por defecto

  // Resumen general
  Map<String, dynamic> _resumenGeneral = {};

  // Entidades con su estado económico
  List<Map<String, dynamic>> _entidadesConEstado = [];

  // Compromisos activos del mes por entidad (batch)
  Map<int, List<Map<String, dynamic>>> _acuerdosPorEntidad = {};

  // Mes actual
  late int _mesActual;
  late int _anioActual;

  // ── Getters de conteo por estado ────────────────────────────────────────────
  int get _cantAlDia => _entidadesConEstado.where((e) {
    final esp = (e['esperado'] as num?)?.toDouble() ?? 0;
    return esp == 0;
  }).length;

  int get _cantSinPago => _entidadesConEstado.where((e) {
    final pag = (e['pagado'] as num?)?.toDouble() ?? 0;
    final tot = (e['totalComprometido'] as num?)?.toDouble() ?? 0;
    return pag == 0 && tot > 0;
  }).length;

  int get _cantParcial => _entidadesConEstado.where((e) {
    final esp = (e['esperado'] as num?)?.toDouble() ?? 0;
    final pag = (e['pagado'] as num?)?.toDouble() ?? 0;
    return esp > 0 && pag > 0;
  }).length;

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _mesActual = ahora.month;
    _anioActual = ahora.year;
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    try {
      // Cargar resumen general
      final resumen = await _plantelSvc.calcularResumenGeneral(_anioActual, _mesActual);

      // Cargar entidades según filtros
      var entidades = await _plantelSvc.listarEntidades(
        rol: _filtroRol == 'TODOS' ? null : _filtroRol,
        soloActivos: _filtroEstado == 'ACTIVOS',
      );

      // Filtrar manualmente si se seleccionó BAJA
      if (_filtroEstado == 'BAJA') {
        entidades = entidades.where((e) => (e['estado_activo'] as int) == 0).toList();
      }

      // Calcular estado económico de cada entidad
      final entidadesConEstado = <Map<String, dynamic>>[];
      for (final entidad in entidades) {
        try {
          final id = entidad['id'] as int;
          final estado = await _plantelSvc.calcularEstadoMensualPorEntidad(
            id,
            _anioActual,
            _mesActual,
          );

          entidadesConEstado.add({
            ...entidad,
            'totalComprometido': estado['totalComprometido'],
            'pagado': estado['pagado'],
            'esperado': estado['esperado'],
            'atrasado': estado['atrasado'],
          });
        } catch (e, stack) {
          // Loguear error individual pero continuar con otros
          await AppDatabase.logLocalError(
            scope: 'plantel_page.cargar_estado_entidad',
            error: e.toString(),
            stackTrace: stack,
            payload: {'entidad_id': entidad['id']},
          );
        }
      }

      // Cargar acuerdos (compromisos) activos del mes para todas las entidades
      final entidadIds = entidades.map((e) => e['id'] as int).toList();
      final acuerdosBatch = await _plantelSvc.obtenerAcuerdosMensualesBatch(
        entidadIds, _anioActual, _mesActual);

      setState(() {
        _resumenGeneral = resumen;
        _entidadesConEstado = entidadesConEstado;
        _acuerdosPorEntidad = acuerdosBatch;
      });
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'plantel_page.cargar_datos',
        error: e.toString(),
        stackTrace: stack,
        payload: {'filtro_rol': _filtroRol, 'filtro_estado': _filtroEstado},
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al cargar datos del plantel. Por favor, intente nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _irADetalle(int entidadId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetalleJugadorPage(entidadId: entidadId),
      ),
    ).then((_) => _cargarDatos()); // Recargar al volver
  }

  void _irAGestionar() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GestionarJugadoresPage()),
    ).then((_) => _cargarDatos());
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= AppSpacing.breakpointTablet;

    return ErpLayout(
      currentRoute: '/plantel',
      title: 'Plantel - ${_nombreMes(_mesActual)} $_anioActual',
      actions: [
        IconButton(
          icon: Icon(_vistaTabla ? Icons.view_module : Icons.table_chart),
          tooltip: _vistaTabla ? 'Ver tarjetas' : 'Ver tabla',
          onPressed: () => setState(() => _vistaTabla = !_vistaTabla),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
              onPressed: _irAGestionar,
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.textPrimary,
              icon: const Icon(Icons.settings),
              label: const Text('Gestionar'),
            ),
      body: _cargando
          ? SkeletonLoader.cards(count: 4)
          : RefreshIndicator(
              onRefresh: _cargarDatos,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.contentPadding),
                children: [
                  if (isDesktop)
                    const SizedBox(height: AppSpacing.lg),
                  const SizedBox(height: AppSpacing.lg),
                  _buildResumenGeneral(),
                  const SizedBox(height: AppSpacing.lg),
                  _buildFiltros(),
                  const SizedBox(height: AppSpacing.lg),
                  if (_entidadesConEstado.isEmpty)
                    EmptyState(
                      icon: Icons.people_outline,
                      title: 'No hay entidades para mostrar',
                      action: FilledButton.icon(
                        onPressed: _irAGestionar,
                        icon: const Icon(Icons.settings, size: 18),
                        label: const Text('Gestionar jugadores'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.textPrimary,
                        ),
                      ),
                    )
                  else if (_vistaTabla)
                    _buildTabla()
                  else
                    _buildTarjetas(),
                ],
              ),
            ),
    );
  }

  Widget _buildResumenGeneral() {
    final totalComprometido = _resumenGeneral['totalMensualComprometido'] as double? ?? 0.0;
    final pagado = _resumenGeneral['pagadoEsteMes'] as double? ?? 0.0;
    final pendiente = _resumenGeneral['pendienteEsteMes'] as double? ?? 0.0;
    final progreso = totalComprometido == 0 ? 0.0 : (pagado / totalComprometido).clamp(0.0, 1.0);
    final totalEntidades = _resumenGeneral['totalEntidades'] as int? ?? 0;

    final kpis = [
      (
        title: 'TOTAL COMPROMETIDO',
        value: Format.moneyNoDecimals(totalComprometido),
        icon: Icons.attach_money,
        color: AppColors.info,
      ),
      (
        title: 'PAGADO ESTE MES',
        value: Format.moneyNoDecimals(pagado),
        icon: Icons.check_circle_outline,
        color: AppColors.ingreso,
      ),
      (
        title: 'PENDIENTE',
        value: Format.moneyNoDecimals(pendiente),
        icon: Icons.pending_outlined,
        color: pendiente > 0 ? AppColors.egreso : AppColors.ingreso,
      ),
      (
        title: 'AL DÍA',
        value: '$_cantAlDia personas',
        icon: Icons.radio_button_checked,
        color: AppColors.ingreso,
      ),
      (
        title: 'PAGO PARCIAL',
        value: '$_cantParcial personas',
        icon: Icons.timelapse,
        color: AppColors.advertencia,
      ),
      (
        title: 'SIN PAGO',
        value: '$_cantSinPago personas',
        icon: Icons.cancel_outlined,
        color: AppColors.egreso,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 6 KPIs en 2 filas de 3
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.contentPadding),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 700;
              if (isWide) {
                return Row(
                  children: kpis.map((k) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: SummaryCard(
                        title: k.title,
                        value: k.value,
                        icon: k.icon,
                        color: k.color,
                      ),
                    ),
                  )).toList(),
                );
              }
              // Layout para pantallas más angostas: 2 columnas
              return Column(
                children: [
                  for (int i = 0; i < kpis.length; i += 2)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Row(
                        children: [
                          Expanded(
                            child: SummaryCard(
                              title: kpis[i].title,
                              value: kpis[i].value,
                              icon: kpis[i].icon,
                              color: kpis[i].color,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          if (i + 1 < kpis.length)
                            Expanded(
                              child: SummaryCard(
                                title: kpis[i + 1].title,
                                value: kpis[i + 1].value,
                                icon: kpis[i + 1].icon,
                                color: kpis[i + 1].color,
                              ),
                            )
                          else
                            const Expanded(child: SizedBox()),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        // Barra de progreso global
        if (totalComprometido > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.contentPadding),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              decoration: AppDecorations.cardOf(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Progreso de pagos del mes', style: AppText.caption),
                      Text(
                        '${(progreso * 100).round()}% completado',
                        style: AppText.label.copyWith(
                          color: progreso == 1.0
                              ? AppColors.ingreso
                              : context.appColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progreso,
                      backgroundColor: context.appColors.bgElevated,
                      valueColor: AlwaysStoppedAnimation(
                          progreso == 1.0 ? AppColors.ingreso : AppColors.advertencia),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${Format.moneyNoDecimals(pagado)} pagado',
                        style: AppText.caption.copyWith(color: AppColors.ingreso),
                      ),
                      Text(
                        '${Format.moneyNoDecimals(pendiente)} pendiente · $totalEntidades personas',
                        style: AppText.caption.copyWith(color: AppColors.egreso),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFiltros() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: AppDecorations.cardOf(context),
      child: Column(
        children: [
          Row(
            children: [
              Text('Rol:', style: AppText.label),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildTabBtn('Todos', 'TODOS', isRol: true),
                      _buildTabBtn('Jugador', 'JUGADOR', isRol: true),
                      _buildTabBtn('DT', 'DT', isRol: true),
                      _buildTabBtn('Ayudante', 'AYUDANTE', isRol: true),
                      _buildTabBtn('PF', 'PF', isRol: true),
                      _buildTabBtn('Otro', 'OTRO', isRol: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text('Estado:', style: AppText.label),
              const SizedBox(width: AppSpacing.sm),
              _buildTabBtn('Activos', 'ACTIVOS', isRol: false),
              _buildTabBtn('Baja', 'BAJA', isRol: false),
              _buildTabBtn('Todos', 'TODOS', isRol: false),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabBtn(String label, String value, {required bool isRol}) {
    final active = isRol ? _filtroRol == value : _filtroEstado == value;
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isRol) {
            _filtroRol = value;
          } else {
            _filtroEstado = value;
          }
        });
        _cargarDatos();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        margin: const EdgeInsets.only(right: AppSpacing.xs),
        decoration: BoxDecoration(
          color: active ? context.appColors.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        ),
        child: Text(
          label,
          style: AppText.titleSm.copyWith(
            fontSize: 12,
            color: active ? context.appColors.textPrimary : context.appColors.textMuted,
          ),
        ),
      ),
    );
  }


  Widget _buildTarjetas() {
    return Column(
      children: _entidadesConEstado.map((entidad) {
        return _buildTarjetaEntidad(entidad);
      }).toList(),
    );
  }

  Widget _buildTarjetaEntidad(Map<String, dynamic> entidad) {
    try {
      final id = entidad['id'] as int;
      final nombre = entidad['nombre']?.toString() ?? 'Sin nombre';
      final rol = entidad['rol']?.toString() ?? 'OTRO';
      final activo = (entidad['estado_activo'] as int?) == 1;
      final totalComprometido = (entidad['totalComprometido'] as num?)?.toDouble() ?? 0.0;
      final pagado = (entidad['pagado'] as num?)?.toDouble() ?? 0.0;
      final esperado = (entidad['esperado'] as num?)?.toDouble() ?? 0.0;

      final estadoPago = esperado == 0 ? 'Al día' : pagado == 0 ? 'Sin pagos' : 'Pendiente';
      final statusType = esperado == 0
          ? StatusType.success
          : pagado == 0
              ? StatusType.danger
              : StatusType.warning;

      final rolColor = _colorPorRol(rol);

      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: InkWell(
          onTap: () => _irADetalle(id),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: AppDecorations.cardOf(context).copyWith(
              color: activo ? context.appColors.bgSurface : context.appColors.bgElevated,
              boxShadow: AppShadows.cardFor(context),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: rolColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _inicialesRol(rol),
                    style: AppText.label.copyWith(
                      color: rolColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              nombre,
                              style: AppText.titleSm.copyWith(
                                decoration: activo ? null : TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                          StatusBadge(label: estadoPago, type: statusType),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(_nombreRol(rol), style: AppText.caption),
                          if (entidad['alias'] != null && (entidad['alias'] as String).isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              '"${entidad['alias']}"',
                              style: AppText.caption.copyWith(fontStyle: FontStyle.italic),
                            ),
                          ],
                        ],
                      ),
                      if (rol == 'JUGADOR') ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (entidad['tipo_contratacion'] != null) ...[
                              StatusBadge(
                                label: entidad['tipo_contratacion'].toString(),
                                type: entidad['tipo_contratacion'] == 'LOCAL'
                                    ? StatusType.info
                                    : StatusType.neutral,
                                fontSize: 10,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                            ],
                            if (entidad['posicion'] != null) ...[
                              Icon(_iconPosicion(entidad['posicion'].toString()),
                                  size: 12, color: context.appColors.textMuted),
                              const SizedBox(width: 4),
                              Text(
                                _nombrePosicion(entidad['posicion'].toString()),
                                style: AppText.caption,
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Text(
                            'Total: \$${_formatMonto(totalComprometido)}',
                            style: AppText.monoSm.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          Text(
                            'Pagado: \$${_formatMonto(pagado)}',
                            style: AppText.monoSm.copyWith(color: AppColors.ingreso),
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          Text(
                            'Pendiente: \$${_formatMonto(esperado)}',
                            style: AppText.monoSm.copyWith(color: AppColors.advertencia),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stack) {
      AppDatabase.logLocalError(
        scope: 'plantel_page.render_tarjeta',
        error: e.toString(),
        stackTrace: stack,
        payload: {'entidad': entidad},
      );

      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: AppDecorations.cardOf(context).copyWith(
            border: Border.all(color: AppColors.advertencia.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning, color: AppColors.advertencia, size: 20),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text('Error al mostrar entidad'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildTabla() {
    // Ancho fijo total de las columnas (para que el scroll horizontal funcione)
    const double totalWidth = 200 + 190 + 110 + 110 + 110 + 130 + 100 + 90 + 32.0; // cols + padding lateral

    return Container(
      decoration: AppDecorations.cardOf(context),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: context.appColors.border)),
                ),
                child: Row(
                  children: [
                    _th('NOMBRE', w: 200),
                    _th('ACUERDOS', w: 190),
                    _th('ESPERADO', w: 110, align: TextAlign.right),
                    _th('PAGADO', w: 110, align: TextAlign.right),
                    _th('PENDIENTE', w: 110, align: TextAlign.right),
                    _th('PROGRESO', w: 130),
                    _th('ESTADO', w: 100),
                    _th('', w: 90),
                  ],
                ),
              ),
              // ── Filas ──────────────────────────────────────────────────────
              ..._entidadesConEstado.map((entidad) {
                try {
                  return _buildTablaRow(entidad);
                } catch (e, stack) {
                  AppDatabase.logLocalError(
                    scope: 'plantel_page.render_tabla_row',
                    error: e.toString(),
                    stackTrace: stack,
                    payload: {'id': entidad['id']},
                  );
                  return Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md),
                    decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              color: context.appColors.border
                                  .withValues(alpha: 0.5))),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning,
                            size: 16, color: AppColors.advertencia),
                        const SizedBox(width: AppSpacing.sm),
                        const Text('Error al mostrar fila'),
                      ],
                    ),
                  );
                }
              }),
              // ── Fila total ─────────────────────────────────────────────────
              _buildTablaTotal(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTablaRow(Map<String, dynamic> entidad) {
    final id = entidad['id'] as int;
    final nombre = entidad['nombre']?.toString() ?? '';
    final rol = entidad['rol']?.toString() ?? '';
    final activo = (entidad['estado_activo'] as int?) == 1;
    final totalComprometido =
        (entidad['totalComprometido'] as num?)?.toDouble() ?? 0.0;
    final pagado = (entidad['pagado'] as num?)?.toDouble() ?? 0.0;
    final esperado = (entidad['esperado'] as num?)?.toDouble() ?? 0.0;
    final progreso = totalComprometido == 0
        ? 1.0
        : (pagado / totalComprometido).clamp(0.0, 1.0);

    final estadoPago = _estadoLabel(esperado, pagado, totalComprometido);
    final statusType = _estadoType(esperado, pagado, totalComprometido);
    final progresoColor = _estadoColor(esperado, pagado, totalComprometido);

    final acuerdos = _acuerdosPorEntidad[id] ?? [];

    return InkWell(
      onTap: () => _irADetalle(id),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: activo ? null : context.appColors.bgElevated,
          border: Border(
            bottom: BorderSide(
                color: context.appColors.border.withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Nombre + rol
            SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    nombre,
                    style: AppText.bodyMd.copyWith(
                      decoration:
                          activo ? null : TextDecoration.lineThrough,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(_nombreRol(rol),
                      style: AppText.caption,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            // Acuerdos chips
            SizedBox(
              width: 190,
              child: acuerdos.isEmpty
                  ? Text('—', style: AppText.caption)
                  : Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: acuerdos.take(3).map((a) {
                        final nombre = (a['nombre'] as String?) ?? '';
                        final label = nombre.length > 12
                            ? '${nombre.substring(0, 11)}…'
                            : nombre;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: context.appColors.bgElevated,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: context.appColors.border),
                          ),
                          child: Text(label,
                              style: AppText.caption
                                  .copyWith(fontSize: 10)),
                        );
                      }).toList()
                        ..addAll(acuerdos.length > 3
                            ? [
                                Container(
                                  padding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color:
                                        context.appColors.bgElevated,
                                    borderRadius:
                                        BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '+${acuerdos.length - 3}',
                                    style: AppText.caption
                                        .copyWith(fontSize: 10),
                                  ),
                                )
                              ]
                            : []),
                    ),
            ),
            // Esperado (total comprometido)
            SizedBox(
              width: 110,
              child: Text(
                '\$ ${_formatMonto(totalComprometido)}',
                style: AppText.monoSm,
                textAlign: TextAlign.right,
              ),
            ),
            // Pagado
            SizedBox(
              width: 110,
              child: Text(
                '\$ ${_formatMonto(pagado)}',
                style:
                    AppText.monoSm.copyWith(color: AppColors.ingreso),
                textAlign: TextAlign.right,
              ),
            ),
            // Pendiente
            SizedBox(
              width: 110,
              child: Text(
                esperado > 0
                    ? '\$ ${_formatMonto(esperado)}'
                    : '✓',
                style: AppText.monoSm.copyWith(
                  color: esperado > 0
                      ? AppColors.egreso
                      : AppColors.ingreso,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            // Barra de progreso
            SizedBox(
              width: 130,
              child: Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progreso,
                        backgroundColor:
                            context.appColors.bgElevated,
                        valueColor:
                            AlwaysStoppedAnimation(progresoColor),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(progreso * 100).round()}%',
                      style: AppText.caption
                          .copyWith(color: progresoColor, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
            // Estado badge
            SizedBox(
              width: 100,
              child: StatusBadge(label: estadoPago, type: statusType),
            ),
            // Botón Detalle
            SizedBox(
              width: 90,
              child: TextButton(
                onPressed: () => _irADetalle(id),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('Detalle',
                    style: AppText.caption
                        .copyWith(color: AppColors.accent)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTablaTotal() {
    final totalEsperado = _entidadesConEstado.fold<double>(
        0, (s, e) => s + ((e['totalComprometido'] as num?)?.toDouble() ?? 0));
    final totalPagado = _entidadesConEstado.fold<double>(
        0, (s, e) => s + ((e['pagado'] as num?)?.toDouble() ?? 0));
    final totalPendiente = _entidadesConEstado.fold<double>(
        0, (s, e) => s + ((e['esperado'] as num?)?.toDouble() ?? 0));

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: context.appColors.bgElevated,
        border: Border(top: BorderSide(color: context.appColors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text('TOTAL',
                style: AppText.label
                    .copyWith(color: context.appColors.textPrimary)),
          ),
          const SizedBox(width: 190),
          SizedBox(
            width: 110,
            child: Text('\$ ${_formatMonto(totalEsperado)}',
                style:
                    AppText.monoSm.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 110,
            child: Text('\$ ${_formatMonto(totalPagado)}',
                style: AppText.monoSm.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.ingreso),
                textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 110,
            child: Text(
                totalPendiente > 0
                    ? '\$ ${_formatMonto(totalPendiente)}'
                    : '✓',
                style: AppText.monoSm.copyWith(
                    fontWeight: FontWeight.bold,
                    color: totalPendiente > 0
                        ? AppColors.egreso
                        : AppColors.ingreso),
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  // ── Helpers de estado ──────────────────────────────────────────────────────

  String _estadoLabel(double esperado, double pagado, double total) {
    if (esperado == 0) return 'Al día';
    if (pagado == 0 && total > 0) return 'Sin pagos';
    return 'Pendiente';
  }

  StatusType _estadoType(double esperado, double pagado, double total) {
    if (esperado == 0) return StatusType.success;
    if (pagado == 0 && total > 0) return StatusType.danger;
    return StatusType.warning;
  }

  Color _estadoColor(double esperado, double pagado, double total) {
    if (esperado == 0) return AppColors.ingreso;
    if (pagado == 0 && total > 0) return AppColors.egreso;
    return AppColors.advertencia;
  }

  Widget _th(String label, {required double w, TextAlign align = TextAlign.left}) {
    return SizedBox(
      width: w,
      child: Text(
        label,
        style: AppText.label,
        textAlign: align,
      ),
    );
  }

  String _formatMonto(double monto) {
    if (monto >= 1000000) {
      return '${(monto / 1000000).toStringAsFixed(1)}M';
    } else if (monto >= 1000) {
      return '${(monto / 1000).toStringAsFixed(0)}k';
    } else {
      return monto.toStringAsFixed(0);
    }
  }

  String _nombreMes(int mes) {
    const meses = [
      'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
      'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'
    ];
    return meses[mes - 1];
  }

  String _nombreRol(String rol) {
    switch (rol) {
      case 'JUGADOR':
        return 'Jugador';
      case 'DT':
        return 'Director Técnico';
      case 'AYUDANTE':
        return 'Ayudante de Campo';
      case 'PF':
        return 'Preparador Físico';
      case 'OTRO':
        return 'Otro';
      default:
        return rol;
    }
  }

  String _inicialesRol(String rol) {
    switch (rol) {
      case 'JUGADOR':
        return 'J';
      case 'DT':
        return 'DT';
      case 'AYUDANTE':
        return 'AC';
      case 'PF':
        return 'PF';
      case 'OTRO':
        return 'O';
      default:
        return '?';
    }
  }

  Color _colorPorRol(String rol) {
    switch (rol) {
      case 'JUGADOR':
        return AppColors.info;
      case 'DT':
        return AppColors.accentDim;
      case 'AYUDANTE':
        return AppColors.accent;
      case 'PF':
        return AppColors.advertencia;
      case 'OTRO':
        return AppColors.textMuted;
      default:
        return AppColors.textMuted;
    }
  }

  String _nombrePosicion(String posicion) {
    switch (posicion) {
      case 'ARQUERO':
        return 'Arquero';
      case 'DEFENSOR':
        return 'Defensor';
      case 'MEDIOCAMPISTA':
        return 'Mediocampista';
      case 'DELANTERO':
        return 'Delantero';
      case 'STAFF_CT':
        return 'Staff CT';
      default:
        return posicion;
    }
  }

  IconData _iconPosicion(String posicion) {
    switch (posicion) {
      case 'ARQUERO':
        return Icons.sports_handball;
      case 'DEFENSOR':
        return Icons.shield;
      case 'MEDIOCAMPISTA':
        return Icons.swap_horiz;
      case 'DELANTERO':
        return Icons.flash_on;
      case 'STAFF_CT':
        return Icons.person;
      default:
        return Icons.sports;
    }
  }
}
