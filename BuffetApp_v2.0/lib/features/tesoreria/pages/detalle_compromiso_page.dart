import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../shared/widgets/responsive_container.dart';
import '../../shared/widgets/breadcrumb.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/skeleton_loader.dart';

import '../../../features/shared/format.dart';
import '../../../features/shared/services/compromisos_service.dart';
import '../../../data/dao/db.dart';
import '../services/categoria_movimiento_service.dart';
import 'editar_compromiso_page.dart';
import 'detalle_movimiento_page.dart';
import 'confirmar_movimiento_page.dart';
import 'detalle_acuerdo_page.dart';

/// Página de detalle de un compromiso financiero.
/// Muestra información completa, próximo vencimiento e historial de movimientos.
class DetalleCompromisoPage extends StatefulWidget {
  final int compromisoId;
  
  const DetalleCompromisoPage({
    super.key,
    required this.compromisoId,
  });

  @override
  State<DetalleCompromisoPage> createState() => _DetalleCompromisoPageState();
}

class _DetalleCompromisoPageState extends State<DetalleCompromisoPage> {
  final _compromisosService = CompromisosService.instance;
  
  Map<String, dynamic>? _compromiso;
  Map<String, dynamic>? _acuerdoOrigen;
  List<Map<String, dynamic>> _movimientos = [];
  DateTime? _proximoVencimiento;
  int? _cuotasRestantes;
  bool _isLoading = true;
  String? _error;
  String? _categoriaNombre;
  Map<int, String> _movimientosCategoriasNombres = {};
  List<Map<String, dynamic>> _cuotas = [];
  bool _cuotasExpanded = true;

  /// Unidad del acuerdo origen: 'ARS' o 'LTS'
  String get _unidadAcuerdo => _acuerdoOrigen?['unidad'] as String? ?? 'ARS';

  /// Formatea un valor según la unidad: litros o pesos ARS
  String _formatearValor(double valor) {
    if (_unidadAcuerdo == 'LTS') {
      return '${valor.toStringAsFixed(2)} lts';
    }
    return Format.money(valor);
  }

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    
    try {
      final compromiso = await _compromisosService.obtenerCompromiso(widget.compromisoId);
      
      if (compromiso == null) {
        setState(() {
          _error = 'Compromiso no encontrado';
          _isLoading = false;
        });
        return;
      }
      
      // Cargar movimientos asociados
      final db = await AppDatabase.instance();
      final movimientos = await db.query(
        'evento_movimiento',
        where: 'compromiso_id = ? AND eliminado = 0',
        whereArgs: [widget.compromisoId],
        orderBy: 'created_ts DESC',
      );
      
      // Cargar cuotas si existen
      final cuotas = await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id = ?',
        whereArgs: [widget.compromisoId],
        orderBy: 'numero_cuota ASC',
      );
      
      // Calcular próximo vencimiento y cuotas restantes
      final proximoVenc = await _compromisosService.calcularProximoVencimiento(widget.compromisoId);
      final cuotasRest = await _compromisosService.calcularCuotasRestantes(widget.compromisoId);
      
      // Cargar acuerdo origen si existe
      Map<String, dynamic>? acuerdoOrigen;
      if (compromiso['acuerdo_id'] != null) {
        acuerdoOrigen = await _compromisosService.obtenerAcuerdoOrigen(widget.compromisoId);
      }
      
      // Cargar nombre de categoría del compromiso
      String? catNombre;
      final codigoCat = compromiso['categoria'] as String?;
      if (codigoCat != null && codigoCat.isNotEmpty) {
        catNombre = await CategoriaMovimientoService.obtenerNombrePorCodigo(codigoCat);
      }
      
      // Cargar nombres de categorías de movimientos
      final Map<int, String> movCategoriasNombres = {};
      for (final mov in movimientos) {
        final movId = mov['id'] as int;
        final movCodigoCat = mov['categoria'] as String?;
        if (movCodigoCat != null && movCodigoCat.isNotEmpty) {
          final nombre = await CategoriaMovimientoService.obtenerNombrePorCodigo(movCodigoCat);
          if (nombre != null) {
            movCategoriasNombres[movId] = nombre;
          }
        }
      }
      
      setState(() {
        _compromiso = compromiso;
        _acuerdoOrigen = acuerdoOrigen;
        _movimientos = movimientos;
        _proximoVencimiento = proximoVenc;
        _cuotasRestantes = cuotasRest;
        _categoriaNombre = catNombre;
        _movimientosCategoriasNombres = movCategoriasNombres;
        _cuotas = cuotas;
        _isLoading = false;
      });
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_compromiso.cargar',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': widget.compromisoId},
      );
      
      setState(() {
        _error = 'Error al cargar los datos del compromiso. Por favor, intente nuevamente.';
        _isLoading = false;
      });
    }
  }

  Future<void> _pausarReactivar() async {
    if (_compromiso == null) return;
    
    final activo = _compromiso!['activo'] == 1;
    
    try {
      if (activo) {
        await _compromisosService.pausarCompromiso(widget.compromisoId);
      } else {
        await _compromisosService.reactivarCompromiso(widget.compromisoId);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(activo ? 'Compromiso pausado' : 'Compromiso reactivado'),
          ),
        );
      }
      
      await _cargarDatos();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al procesar. Intente nuevamente.')),
        );
      }
    }
  }

  Future<void> _desactivar() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar desactivación'),
        content: const Text(
          '¿Desactivar este compromiso?\n\n'
          'No se puede desactivar si tiene movimientos esperados pendientes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DESACTIVAR', style: TextStyle(color: AppColors.egreso)),
          ),
        ],
      ),
    );
    
    if (confirmar != true) return;
    
    try {
      await _compromisosService.desactivarCompromiso(widget.compromisoId);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Compromiso desactivado')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al procesar. Intente nuevamente.')),
        );
      }
    }
  }

  Future<void> _editar() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditarCompromisoPage(compromisoId: widget.compromisoId),
      ),
    );
    
    if (result == true) {
      await _cargarDatos();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppBarBreadcrumb(
          items: [
            BreadcrumbItem(
              label: 'Compromisos',
              icon: Icons.assignment,
              onTap: () => Navigator.of(context).popUntil((route) => route.isFirst),
            ),
            BreadcrumbItem(
              label: _compromiso != null 
                ? (_compromiso!['nombre'] as String? ?? 'Detalle')
                : 'Detalle',
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargarDatos,
            tooltip: 'Actualizar',
          ),
          if (_compromiso != null && _compromiso!['eliminado'] == 0) ...[
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _editar,
              tooltip: 'Editar',
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'pausar_reactivar') {
                  _pausarReactivar();
                } else if (value == 'desactivar') {
                  _desactivar();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'pausar_reactivar',
                  child: Text(
                    _compromiso!['activo'] == 1 ? 'Pausar' : 'Reactivar',
                  ),
                ),
                const PopupMenuItem(
                  value: 'desactivar',
                  child: Text('Desactivar', style: TextStyle(color: AppColors.egreso)),
                ),
              ],
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return SkeletonLoader.list(count: 5);
    }
    
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: AppColors.egreso),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _cargarDatos,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    
    if (_compromiso == null) {
      return const Center(child: Text('Compromiso no encontrado'));
    }
    
    return ResponsiveContainer(
      maxWidth: 800,
      child: RefreshIndicator(
        onRefresh: _cargarDatos,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            _buildInfoCard(),
            const SizedBox(height: 16),
            if (_acuerdoOrigen != null) ...[
              _buildOrigenAcuerdoCard(),
              const SizedBox(height: 16),
            ],
            _buildEstadoFinanciero(),
            const SizedBox(height: 16),
            _buildEstadoCard(),
            const SizedBox(height: 16),
            if (_cuotas.isNotEmpty) ...[
              _buildCuotasCard(),
              const SizedBox(height: 16),
            ],
            _buildMovimientosCard(),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildInfoCard() {
    final comp = _compromiso!;
    final activo = comp['activo'] == 1;
    final eliminado = comp['eliminado'] == 1;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    comp['nombre'] as String,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                if (eliminado)
                  const Chip(
                    label: Text('DESACTIVADO', style: TextStyle(fontSize: 10)),
                    backgroundColor: AppColors.egreso,
                    labelStyle: TextStyle(color: Colors.white),
                  )
                else if (!activo)
                  const Chip(
                    label: Text('PAUSADO', style: TextStyle(fontSize: 10)),
                    backgroundColor: AppColors.advertencia,
                    labelStyle: TextStyle(color: Colors.white),
                  )
                else
                  const Chip(
                    label: Text('ACTIVO', style: TextStyle(fontSize: 10)),
                    backgroundColor: AppColors.ingreso,
                    labelStyle: TextStyle(color: Colors.white),
                  ),
              ],
            ),
            const Divider(),
            _buildInfoRow('Tipo', comp['tipo'] as String),
            _buildInfoRow('Monto', _formatearValor((comp['monto'] as num?)?.toDouble() ?? 0.0)),
            _buildInfoRow('Frecuencia', comp['frecuencia'] as String),
            if (comp['frecuencia_dias'] != null)
              _buildInfoRow('Días', '${comp['frecuencia_dias']} días'),
            _buildInfoRow('Categoría', _categoriaNombre ?? (comp['categoria'] as String? ?? '—')),
            _buildInfoRow(
              'Fecha inicio',
              _formatFecha(comp['fecha_inicio'] as String?),
            ),
            if (comp['fecha_fin'] != null)
              _buildInfoRow(
                'Fecha fin',
                _formatFecha(comp['fecha_fin'] as String?),
              ),
            if (comp['observaciones'] != null && (comp['observaciones'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Observaciones:',
                      style: TextStyle(fontSize: 12, color: context.appColors.textMuted),
                    ),
                    const SizedBox(height: 4),
                    Text(comp['observaciones'] as String),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEstadoCard() {
    final comp = _compromiso!;
    // FASE 22.1: Usar _cuotas.length para mostrar cuotas generadas realmente
    final cuotasTotales = _cuotas.isNotEmpty ? _cuotas.length : (comp['cuotas'] as int?);
    // Contar cuotas confirmadas desde _cuotas
    final cuotasConfirmadas = _cuotas.where((c) => c['estado'] == 'CONFIRMADO').length;
    final activo = comp['activo'] == 1;
    final eliminado = comp['eliminado'] == 1;
    
    return Card(
      color: context.appColors.infoDim,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Estado del Compromiso',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (cuotasTotales != null) ...[
              _buildInfoRow(
                'Cuotas',
                '$cuotasConfirmadas de $cuotasTotales confirmadas',
              ),
              if (_cuotasRestantes != null)
                _buildInfoRow('Restantes', '$_cuotasRestantes cuotas'),
              // Para acuerdos LTS: mostrar litros pagados y remanente
              if (_unidadAcuerdo == 'LTS')
                Builder(builder: (_) {
                  final litrosPagados = _cuotas
                      .where((c) => c['estado'] == 'CONFIRMADO')
                      .fold(0.0, (s, c) => s + ((c['cantidad_litros'] as num?)?.toDouble() ?? 0.0));
                  final litrosEsperados = _cuotas.fold(
                      0.0, (s, c) => s + ((c['monto_esperado'] as num?)?.toDouble() ?? 0.0));
                  final litrosRemanentes = litrosEsperados - litrosPagados;
                  return Column(
                    children: [
                      _buildInfoRow('Litros pagados', '${litrosPagados.toStringAsFixed(2)} lts'),
                      _buildInfoRow('Litros remanente', '${litrosRemanentes.toStringAsFixed(2)} lts'),
                    ],
                  );
                }),
            ] else
              _buildInfoRow('Cuotas', 'Sin límite (recurrente)'),
            if (_proximoVencimiento != null) ...[
              _buildInfoRow(
                'Próximo vencimiento',
                DateFormat('dd/MM/yyyy').format(_proximoVencimiento!),
              ),
              // Botón para registrar pago/cobro
              if (activo && !eliminado) ...[
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ConfirmarMovimientoPage(
                          compromisoId: widget.compromisoId,
                          fechaVencimiento: _proximoVencimiento!,
                          montoSugerido: comp['monto'] as double,
                          tipo: comp['tipo'] as String,
                          categoria: comp['categoria'] as String? ?? '',
                          unidadAcuerdo: _unidadAcuerdo,
                        ),
                      ),
                    );
                    if (result == true) {
                      await _cargarDatos();
                    }
                  },
                  icon: Icon(
                    comp['tipo'] == 'INGRESO' ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 18,
                  ),
                  label: Text(
                    comp['tipo'] == 'INGRESO' ? 'Registrar cobro' : 'Registrar pago',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ingreso,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 40),
                  ),
                ),
              ],
            ] else if (activo && !eliminado)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No hay próximos vencimientos calculados',
                  style: TextStyle(color: context.appColors.textMuted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCuotasCard() {
    final comp = _compromiso!;
    final activo = comp['activo'] == 1;
    final eliminado = comp['eliminado'] == 1;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                setState(() {
                  _cuotasExpanded = !_cuotasExpanded;
                });
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Cuotas Generadas',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      Text(
                        '${_cuotas.length} total',
                        style: TextStyle(fontSize: 12, color: context.appColors.textMuted),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _cuotasExpanded ? Icons.expand_less : Icons.expand_more,
                        color: context.appColors.textMuted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_cuotasExpanded) ...[
              const SizedBox(height: 12),
              SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(context.appColors.bgElevated),
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('Nro', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Fecha', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Monto', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Estado', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Acciones', style: TextStyle(fontWeight: FontWeight.bold))),
                ],
                rows: _cuotas.map((cuota) {
                  final estado = cuota['estado'] as String;
                  final numeroCuota = cuota['numero_cuota'] as int;
                  final fechaProgramada = cuota['fecha_programada'] as String;
                  final montoEsperado = (cuota['monto_esperado'] as num).toDouble();
                  
                  return DataRow(
                    cells: [
                      DataCell(Text('$numeroCuota')),
                      DataCell(Text(
                        DateFormat('dd/MM/yyyy').format(DateTime.parse(fechaProgramada)),
                      )),
                      DataCell(Text(
                        _formatearValor(montoEsperado),
                      )),
                      DataCell(_buildEstadoBadge(estado)),
                      DataCell(
                        estado == 'ESPERADO' && activo && !eliminado
                            ? IconButton(
                                icon: const Icon(Icons.payment, size: 20),
                                tooltip: 'Registrar pago',
                                onPressed: () async {
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ConfirmarMovimientoPage(
                                        compromisoId: widget.compromisoId,
                                        fechaVencimiento: DateTime.parse(fechaProgramada),
                                        montoSugerido: montoEsperado,
                                        tipo: comp['tipo'] as String,
                                        categoria: comp['categoria'] as String? ?? '',
                                        unidadAcuerdo: _unidadAcuerdo,
                                      ),
                                    ),
                                  );
                                  if (result == true) {
                                    await _cargarDatos();
                                  }
                                },
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEstadoBadge(String estado) {
    Color color;
    IconData icon;
    
    switch (estado) {
      case 'CONFIRMADO':
        color = AppColors.ingreso;
        icon = Icons.check_circle;
        break;
      case 'CANCELADO':
        color = AppColors.egreso;
        icon = Icons.cancel;
        break;
      case 'ESPERADO':
      default:
        color = AppColors.advertencia;
        icon = Icons.schedule;
        break;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            estado,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMovimientosCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Historial de Movimientos',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${_movimientos.length} total',
                  style: TextStyle(fontSize: 12, color: context.appColors.textMuted),
                ),
              ],
            ),
            const Divider(),
            if (_movimientos.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No hay movimientos registrados',
                    style: TextStyle(color: context.appColors.textMuted),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _movimientos.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final mov = _movimientos[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: mov['tipo'] == 'INGRESO'
                          ? context.appColors.ingresoDim
                          : context.appColors.egresoDim,
                      child: Icon(
                        mov['tipo'] == 'INGRESO'
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
                        color: mov['tipo'] == 'INGRESO'
                            ? AppColors.ingreso
                            : AppColors.egreso,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      Format.money(mov['monto'] as double),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_movimientosCategoriasNombres[mov['id'] as int] ?? (mov['categoria'] as String? ?? 'Sin categoría')),
                        Text(
                          _formatFechaTs(mov['created_ts'] as int?),
                          style: TextStyle(fontSize: 11, color: context.appColors.textMuted),
                        ),
                      ],
                    ),
                    trailing: Chip(
                      label: Text(
                        mov['estado'] as String? ?? 'CONFIRMADO',
                        style: const TextStyle(fontSize: 10),
                      ),
                      backgroundColor: mov['estado'] == 'CONFIRMADO'
                          ? context.appColors.ingresoDim
                          : context.appColors.advertenciaDim,
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DetalleMovimientoPage(
                            movimientoId: mov['id'] as int,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: context.appColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFecha(String? fecha) {
    if (fecha == null) return '—';
    try {
      final dt = DateTime.parse(fecha);
      return DateFormat('dd/MM/yyyy').format(dt);
    } catch (_) {
      return fecha;
    }
  }

  String _formatFechaTs(int? ts) {
    if (ts == null) return '—';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      return DateFormat('dd/MM/yyyy HH:mm').format(dt);
    } catch (_) {
      return '—';
    }
  }

  /// Widget para mostrar el estado financiero (Pagado/Remanente)
  Widget _buildEstadoFinanciero() {
    return FutureBuilder<Map<String, double>>(
      future: _calcularEstadoFinanciero(widget.compromisoId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }

        final pagado = snapshot.data!['pagado'] ?? 0.0;
        final remanente = snapshot.data!['remanente'] ?? 0.0;
        final total = pagado + remanente;
        final esLts = _unidadAcuerdo == 'LTS';

        return Card(
          color: context.appColors.infoDim,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Estado Financiero',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            esLts ? 'Litros Pagados' : 'Pagado',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColors.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            esLts
                                ? '${pagado.toStringAsFixed(2)} lts'
                                : Format.money(pagado),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.ingreso,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 40,
                      color: context.appColors.border,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            esLts ? 'Litros Remanentes' : 'Remanente',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColors.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            esLts
                                ? '${remanente.toStringAsFixed(2)} lts'
                                : Format.money(remanente),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.advertencia,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (total > 0) ...[
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text(
                        'Total: ',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        esLts
                            ? '${total.toStringAsFixed(2)} lts'
                            : Format.money(total),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<Map<String, double>> _calcularEstadoFinanciero(int compromisoId) async {
    if (_unidadAcuerdo == 'LTS') {
      // Para acuerdos LTS: usar cantidad_litros pagados y monto_esperado (en lts) remanente
      final pagado = _cuotas
          .where((c) => c['estado'] == 'CONFIRMADO')
          .fold(0.0, (s, c) => s + ((c['cantidad_litros'] as num?)?.toDouble() ?? 0.0));
      final remanente = _cuotas
          .where((c) => c['estado'] == 'ESPERADO')
          .fold(0.0, (s, c) => s + ((c['monto_esperado'] as num?)?.toDouble() ?? 0.0));
      return {'pagado': pagado, 'remanente': remanente};
    }
    final pagado = await _compromisosService.calcularMontoPagado(compromisoId);
    final remanente = await _compromisosService.calcularMontoRemanente(compromisoId);
    return {'pagado': pagado, 'remanente': remanente};
  }

  /// Widget para mostrar información del acuerdo origen
  Widget _buildOrigenAcuerdoCard() {
    if (_acuerdoOrigen == null) return const SizedBox.shrink();
    
    final acuerdo = _acuerdoOrigen!;
    final activo = acuerdo['activo'] == 1;
    
    return Card(
      color: context.appColors.accentDim,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.handshake, color: context.appColors.accentLight),
                const SizedBox(width: 8),
                const Text(
                  'Origen: Acuerdo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (!activo)
                  Chip(
                    label: const Text('FINALIZADO', style: TextStyle(fontSize: 10)),
                    backgroundColor: context.appColors.bgElevated,
                    labelStyle: TextStyle(color: context.appColors.textSecondary),
                  ),
              ],
            ),
            const Divider(),
            _buildInfoRow('Nombre', acuerdo['nombre'] as String? ?? '—'),
            _buildInfoRow('Modalidad', acuerdo['modalidad'] as String? ?? '—'),
            _buildInfoRow('Frecuencia', acuerdo['frecuencia'] as String? ?? '—'),
            if (acuerdo['monto_total'] != null)
              _buildInfoRow(
                'Monto Total',
                _formatearValor((acuerdo['monto_total'] as num).toDouble()),
              ),
            if (acuerdo['monto_periodico'] != null)
              _buildInfoRow(
                'Monto Periódico',
                _formatearValor((acuerdo['monto_periodico'] as num).toDouble()),
              ),
            if (acuerdo['cuotas'] != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'Cuota ${_compromiso!['numero_cuota'] ?? '?'} de ${acuerdo['cuotas']}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.appColors.accentLight,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                final resultado = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DetalleAcuerdoPage(
                      acuerdoId: acuerdo['id'] as int,
                    ),
                  ),
                );
                if (resultado == true) {
                  await _cargarDatos();
                }
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Ver Acuerdo Completo'),
              style: ElevatedButton.styleFrom(
                backgroundColor: context.appColors.accentDim,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 36),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
