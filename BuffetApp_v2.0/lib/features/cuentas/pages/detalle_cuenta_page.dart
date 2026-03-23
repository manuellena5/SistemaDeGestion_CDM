import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/dao/db.dart';
import '../../../domain/models.dart';
import '../../shared/format.dart';
import '../../shared/widgets/responsive_container.dart';
import '../../tesoreria/services/cuenta_service.dart';
import '../../tesoreria/services/categoria_movimiento_service.dart';
import '../../tesoreria/pages/detalle_movimiento_page.dart';
import '../../tesoreria/pages/crear_movimiento_page.dart';
import 'transferencia_page.dart';

/// Pantalla de detalle de una cuenta de fondos
/// Muestra el saldo actual y el listado de movimientos
class DetalleCuentaPage extends StatefulWidget {
  final CuentaFondos cuenta;
  
  const DetalleCuentaPage({super.key, required this.cuenta});

  @override
  State<DetalleCuentaPage> createState() => _DetalleCuentaPageState();
}

class _DetalleCuentaPageState extends State<DetalleCuentaPage> {
  final _cuentaService = CuentaService();
  
  late CuentaFondos _cuenta;
  double _saldoActual = 0.0;
  List<Map<String, dynamic>> _movimientos = [];
  bool _cargando = true;
  DateTime _mesSeleccionado = DateTime.now();

  @override
  void initState() {
    super.initState();
    _cuenta = widget.cuenta;
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    try {
      setState(() => _cargando = true);

      // Recargar datos de la cuenta (estado puede haber cambiado)
      final cuentaActualizada = await _cuentaService.obtenerPorId(widget.cuenta.id);
      if (cuentaActualizada != null && mounted) {
        setState(() => _cuenta = cuentaActualizada);
      }
      
      // Cargar saldo actual
      final saldo = await _cuentaService.obtenerSaldo(widget.cuenta.id);
      
      // Cargar movimientos del mes seleccionado
      final db = await AppDatabase.instance();
      
      // Calcular rango del mes
      final primerDia = DateTime(_mesSeleccionado.year, _mesSeleccionado.month, 1);
      final ultimoDia = DateTime(_mesSeleccionado.year, _mesSeleccionado.month + 1, 0, 23, 59, 59);
      
      final movimientos = await db.query(
        'evento_movimiento',
        where: 'cuenta_id = ? AND eliminado = 0 AND created_ts >= ? AND created_ts <= ?',
        whereArgs: [
          _cuenta.id,
          primerDia.millisecondsSinceEpoch,
          ultimoDia.millisecondsSinceEpoch,
        ],
        orderBy: 'created_ts DESC', // De más nuevo a más viejo
      );
      
      if (mounted) {
        setState(() {
          _saldoActual = saldo;
          _movimientos = movimientos.map((m) => Map<String, dynamic>.from(m)).toList();
          _cargando = false;
        });
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_cuenta_page.cargar',
        error: e,
        stackTrace: st,
        payload: {'cuenta_id': widget.cuenta.id, 'mes': _mesSeleccionado.toString()},
      );
      
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cargar datos: ${e.toString()}'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  void _navegarATransferencia() async {
    final resultado = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TransferenciaPage(cuentaOrigenId: _cuenta.id),
      ),
    );
    
    if (resultado == true) {
      _cargarDatos();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_cuenta.nombre),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargarDatos,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ResponsiveContainer(
              maxWidth: 1200,
              child: Column(
                children: [
                  _buildHeader(),
                  _buildSelectorMes(),
                  _buildAcciones(),
                  const Divider(),
                  Expanded(child: _buildMovimientos()),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Card(
      margin: const EdgeInsets.all(16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Saldo actual
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Saldo Actual',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                Text(
                  formatCurrency(_saldoActual),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: _saldoActual >= 0 ? AppColors.ingreso : AppColors.egreso,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Información de la cuenta
            _buildInfoRow('Tipo', _cuenta.tipo),
            _buildInfoRow(
              'Estado',
              _cuenta.estadoCuenta == 'ACTIVA'
                  ? 'Activa'
                  : _cuenta.estadoCuenta == 'LIQUIDADA'
                      ? 'Liquidada'
                      : 'Inactiva',
              color: _cuenta.estadoCuenta == 'ACTIVA'
                  ? AppColors.ingreso
                  : _cuenta.estadoCuenta == 'LIQUIDADA'
                      ? AppColors.advertencia
                      : AppColors.textMuted,
            ),
            _buildInfoRow('Saldo inicial', formatCurrency(_cuenta.saldoInicial)),
            if (_cuenta.tieneComision && _cuenta.comisionPorcentaje != null)
              _buildInfoRow(
                'Comisión',
                '${_cuenta.comisionPorcentaje}%',
                color: AppColors.advertencia,
              ),
            if (_cuenta.bancoNombre != null)
              _buildInfoRow('Banco', _cuenta.bancoNombre!),
            if (_cuenta.cbuAlias != null)
              _buildInfoRow('CBU/Alias', _cuenta.cbuAlias!),
            if (_cuenta.observaciones != null)
              _buildInfoRow('Observaciones', _cuenta.observaciones!),
            if (_cuenta.fechaFinPlazo != null)
              _buildInfoRow(
                'Vencimiento',
                (() {
                  final fecha = DateTime.tryParse(_cuenta.fechaFinPlazo!);
                  return fecha != null ? DateFormat('dd/MM/yyyy').format(fecha) : _cuenta.fechaFinPlazo!;
                })(),
              ),
          ],
        ),
      ),
    );
  }
  Widget _buildInfoRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 14, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectorMes() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                _mesSeleccionado = DateTime(
                  _mesSeleccionado.year,
                  _mesSeleccionado.month - 1,
                );
              });
              _cargarDatos();
            },
            tooltip: 'Mes anterior',
          ),
          Expanded(
            child: Center(
              child: Text(
                DateFormat('MMMM yyyy', 'es_AR').format(_mesSeleccionado),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                _mesSeleccionado = DateTime(
                  _mesSeleccionado.year,
                  _mesSeleccionado.month + 1,
                );
              });
              _cargarDatos();
            },
            tooltip: 'Mes siguiente',
          ),
          IconButton(
            icon: const Icon(Icons.today),
            onPressed: () {
              setState(() {
                _mesSeleccionado = DateTime.now();
              });
              _cargarDatos();
            },
            tooltip: 'Mes actual',
          ),
        ],
      ),
    );
  }

  Widget _buildAcciones() {
    final esInversion = _cuenta.tipo == 'INVERSION';
    final estaActiva = _cuenta.estadoCuenta == 'ACTIVA';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Info de plazo fijo
          if (esInversion && _cuenta.fechaFinPlazo != null)
            _buildPlazoFijoInfo(),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _navegarATransferencia,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Transferir'),
                ),
              ),
              if (esInversion) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: estaActiva ? _mostrarDialogoLiquidarIntereses : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.ingreso,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.savings),
                    label: const Text('Liquidar intereses'),
                  ),
                ),
              ],
            ],
          ),
          // Botón desactivar / reactivar (no mostrar para LIQUIDADA)
          if (_cuenta.estadoCuenta == 'ACTIVA') ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _desactivarCuenta,
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.advertencia),
              icon: const Icon(Icons.block),
              label: const Text('Desactivar cuenta'),
            ),
          ] else if (_cuenta.estadoCuenta == 'INACTIVA') ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _reactivarCuenta,
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.ingreso),
              icon: const Icon(Icons.check_circle),
              label: const Text('Reactivar cuenta'),
            ),
          ] else if (_cuenta.estadoCuenta == 'LIQUIDADA') ...[
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock, size: 16, color: AppColors.textMuted),
                SizedBox(width: 6),
                Text('Plazo fijo liquidado', style: TextStyle(color: AppColors.textMuted)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlazoFijoInfo() {
    final fechaVenc = DateTime.tryParse(_cuenta.fechaFinPlazo!);
    if (fechaVenc == null) return const SizedBox.shrink();
    
    final hoy = DateTime.now();
    final diasRestantes = fechaVenc.difference(DateTime(hoy.year, hoy.month, hoy.day)).inDays;
    final vencido = diasRestantes < 0;
    final proximo = !vencido && diasRestantes <= 7;
    final color = vencido
        ? AppColors.egreso
        : proximo
            ? AppColors.advertencia
            : AppColors.ingreso;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            vencido ? Icons.warning_amber : Icons.event,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  vencido
                      ? 'Plazo fijo vencido'
                      : proximo
                          ? 'Plazo fijo próximo a vencer'
                          : 'Plazo fijo vigente',
                  style: TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  vencido
                      ? 'Venció el ${DateFormat('dd/MM/yyyy').format(fechaVenc)}'
                      : 'Vence: ${DateFormat('dd/MM/yyyy').format(fechaVenc)} ($diasRestantes días)',
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _mostrarDialogoLiquidarIntereses() {
    final cuenta = _cuenta;
    final montoCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.savings, color: AppColors.ingreso, size: 28),
            SizedBox(width: 8),
            Text('Liquidar Plazo Fijo'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cuenta: ${cuenta.nombre}'),
            const SizedBox(height: 16),
            TextField(
              controller: montoCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Intereses obtenidos *',
                prefixText: '\$ ',
                border: OutlineInputBorder(),
                hintText: 'Ingresá el monto de intereses recibidos',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final monto = double.tryParse(
                montoCtrl.text.trim().replaceAll(',', '.'),
              );
              if (monto == null || monto <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ingresá un monto válido')),
                );
                return;
              }
              Navigator.pop(ctx);
              _confirmarRegistrarIntereses(monto);
            },
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }

  void _confirmarRegistrarIntereses(double monto) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.add_circle, color: AppColors.ingreso, size: 28),
            SizedBox(width: 8),
            Text('Registrar intereses'),
          ],
        ),
        content: Text(
          '¿Querés registrar \$${Format.money(monto)} como ingreso por intereses?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('No, cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _liquidarYRegistrar(monto);
            },
            child: const Text('Sí, registrar'),
          ),
        ],
      ),
    );
  }

  void _navegarACrearMovimientoIntereses(double monto) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearMovimientoPage(
          cuentaIdInicial: _cuenta.id,
          tipoInicial: 'INGRESO',
          categoriaInicial: 'INTE',
          montoInicial: monto,
          descripcionInicial: 'Intereses - ${_cuenta.nombre}',
        ),
      ),
    );
    
    if (mounted) {
      _cargarDatos();
    }
  }

  Widget _buildMovimientos() {
    if (_movimientos.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: AppColors.textMuted),
            SizedBox(height: 16),
            Text(
              'No hay movimientos en este mes',
              style: TextStyle(fontSize: 16, color: AppColors.textMuted),
            ),
          ],
        ),
      );
    }

    return FutureBuilder<double>(
      future: _calcularSaldoInicialMes(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        
        final saldoInicial = snapshot.data!;
        
        // FASE 22.4: Crear lista de filas con saldos acumulados correctamente
        // Los movimientos están ordenados DESC (más nuevo primero),
        // pero el saldo debe calcularse desde el más antiguo al más nuevo
        final movimientosConSaldo = <Map<String, dynamic>>[];
        double saldoAcumulado = saldoInicial;
        
        // Invertir para calcular saldos de antiguo a nuevo
        final movimientosReversed = _movimientos.reversed.toList();
        
        for (final mov in movimientosReversed) {
          final tipo = mov['tipo'] as String;
          final monto = (mov['monto'] as num?)?.toDouble() ?? 0.0;
          
          // Actualizar saldo acumulado
          if (tipo == 'INGRESO') {
            saldoAcumulado += monto;
          } else {
            saldoAcumulado -= monto;
          }
          
          movimientosConSaldo.add({
            ...mov,
            '_saldo_acumulado': saldoAcumulado,
          });
        }
        
        // Volver a invertir para mostrar de más nuevo a más viejo
        final filasConSaldo = movimientosConSaldo.reversed.toList();
        
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Saldo inicial del mes
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.info.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'Saldo inicial del mes: ',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          formatCurrency(saldoInicial),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: saldoInicial >= 0 ? AppColors.ingreso : AppColors.egreso,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Tabla de movimientos
                  DataTable(
                    headingRowColor: WidgetStateProperty.all(
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    columns: const [
                      DataColumn(label: Text('Fecha', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Tipo', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Categoría', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Monto', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Saldo', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Acciones', style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                    rows: filasConSaldo.map((mov) {
                      final tipo = mov['tipo'] as String;
                      final monto = (mov['monto'] as num?)?.toDouble() ?? 0.0;
                      final categoriaCode = mov['categoria'] as String? ?? tipo;
                      final movId = mov['id'] as int;
                      final createdTs = mov['created_ts'] as int;
                      final fecha = DateTime.fromMillisecondsSinceEpoch(createdTs);
                      final saldoEnEsteFila = mov['_saldo_acumulado'] as double;
                      
                      return DataRow(
                        cells: [
                          DataCell(Text(DateFormat('dd/MM/yyyy').format(fecha))),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: tipo == 'INGRESO' ? AppColors.ingresoDim : AppColors.egresoDim,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                tipo,
                                style: TextStyle(
                                  color: tipo == 'INGRESO' ? AppColors.ingreso : AppColors.egreso,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          DataCell(
                            FutureBuilder<String?>(
                              future: CategoriaMovimientoService.obtenerNombrePorCodigo(categoriaCode),
                              builder: (context, snapshot) {
                                return Text(snapshot.data ?? categoriaCode);
                              },
                            ),
                          ),
                          DataCell(
                            Text(
                              '${tipo == 'INGRESO' ? '+' : '-'} ${formatCurrency(monto)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: tipo == 'INGRESO' ? AppColors.ingreso : AppColors.egreso,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              formatCurrency(saldoEnEsteFila),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: saldoEnEsteFila >= 0 ? AppColors.ingreso : AppColors.egreso,
                              ),
                            ),
                          ),
                          DataCell(
                            IconButton(
                              icon: const Icon(Icons.info_outline, size: 20),
                              tooltip: 'Ver detalle',
                              onPressed: () async {
                                final result = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => DetalleMovimientoPage(movimientoId: movId),
                                  ),
                                );
                                if (result == true && mounted) {
                                  _cargarDatos();
                                }
                              },
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Saldo final del mes
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.ingreso.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.ingreso.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'Saldo final del mes: ',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          formatCurrency(filasConSaldo.isNotEmpty ? filasConSaldo.first['_saldo_acumulado'] as double : saldoInicial),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: (filasConSaldo.isNotEmpty ? filasConSaldo.first['_saldo_acumulado'] as double : saldoInicial) >= 0 ? AppColors.ingreso : AppColors.egreso,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<double> _calcularSaldoInicialMes() async {
    try {
      final db = await AppDatabase.instance();
      
      // Saldo inicial de la cuenta
      double saldo = _cuenta.saldoInicial;
      
      // Sumar/restar todos los movimientos anteriores al mes seleccionado
      final primerDiaMes = DateTime(_mesSeleccionado.year, _mesSeleccionado.month, 1);
      
      final movimientosAnteriores = await db.query(
        'evento_movimiento',
        where: 'cuenta_id = ? AND eliminado = 0 AND created_ts < ?',
        whereArgs: [_cuenta.id, primerDiaMes.millisecondsSinceEpoch],
      );
      
      for (final mov in movimientosAnteriores) {
        final tipo = mov['tipo'] as String;
        final monto = (mov['monto'] as num?)?.toDouble() ?? 0.0;
        
        if (tipo == 'INGRESO') {
          saldo += monto;
        } else {
          saldo -= monto;
        }
      }
      
      return saldo;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_cuenta_page.calcular_saldo_inicial',
        error: e,
        stackTrace: st,
      );
      return _cuenta.saldoInicial;
    }
  }

  /// Liquida el plazo fijo y navega a crear el movimiento de intereses
  Future<void> _liquidarYRegistrar(double monto) async {
    try {
      await _cuentaService.liquidar(_cuenta.id);
      if (!mounted) return;
      _navegarACrearMovimientoIntereses(monto);
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_cuenta_page.liquidar',
        error: e,
        stackTrace: st,
        payload: {'cuenta_id': _cuenta.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al liquidar el plazo fijo. Intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  void _desactivarCuenta() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desactivar cuenta'),
        content: Text('¿Desactivar "${_cuenta.nombre}"? La cuenta dejará de aparecer en el listado principal.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.advertencia),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    try {
      await _cuentaService.desactivar(_cuenta.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuenta desactivada')),
        );
        _cargarDatos();
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_cuenta_page.desactivar',
        error: e,
        stackTrace: st,
        payload: {'cuenta_id': _cuenta.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo desactivar la cuenta. Intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  void _reactivarCuenta() async {
    try {
      await _cuentaService.reactivar(_cuenta.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuenta reactivada')),
        );
        _cargarDatos();
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'detalle_cuenta_page.reactivar',
        error: e,
        stackTrace: st,
        payload: {'cuenta_id': _cuenta.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo reactivar la cuenta. Intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }
}
