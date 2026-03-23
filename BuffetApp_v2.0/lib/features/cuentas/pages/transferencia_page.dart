import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/dao/db.dart';
import '../../../domain/models.dart';
import '../../shared/state/app_settings.dart';
import '../../shared/format.dart';
import '../../shared/widgets/responsive_container.dart';
import '../../tesoreria/services/cuenta_service.dart';
import '../../tesoreria/services/transferencia_service.dart';

/// Pantalla para crear una transferencia entre cuentas
class TransferenciaPage extends StatefulWidget {
  final int? cuentaOrigenId;
  final int? cuentaDestinoId;
  
  const TransferenciaPage({
    super.key,
    this.cuentaOrigenId,
    this.cuentaDestinoId,
  });

  @override
  State<TransferenciaPage> createState() => _TransferenciaPageState();
}

class _TransferenciaPageState extends State<TransferenciaPage> {
  final _formKey = GlobalKey<FormState>();
  final _cuentaService = CuentaService();
  final _transferenciaService = TransferenciaService();
  
  final _montoCtrl = TextEditingController();
  final _observacionCtrl = TextEditingController();
  
  List<CuentaFondos> _cuentas = [];
  List<Map<String, dynamic>> _metodosPago = [];
  int? _cuentaOrigenId;
  int? _cuentaDestinoId;
  int? _medioPagoId;
  bool _cargando = true;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _cuentaOrigenId = widget.cuentaOrigenId;
    _cuentaDestinoId = widget.cuentaDestinoId;
    _cargarDatos();
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _observacionCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    try {
      setState(() => _cargando = true);
      
      final settings = context.read<AppSettings>();
      final unidadId = settings.disciplinaActivaId;
      
      if (unidadId == null) {
        if (mounted) {
          setState(() => _cargando = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Seleccione una unidad de gestión')),
          );
        }
        return;
      }

      // Cargar cuentas activas de la unidad
      final cuentas = await _cuentaService.listarPorUnidad(unidadId, soloActivas: true);
      
      // Cargar métodos de pago
      final db = await AppDatabase.instance();
      final metodosPago = await db.query('metodos_pago', orderBy: 'id ASC');
      
      if (mounted) {
        setState(() {
          _cuentas = cuentas;
          _metodosPago = metodosPago.map((m) => Map<String, dynamic>.from(m)).toList();
          _medioPagoId = _metodosPago.isNotEmpty ? (_metodosPago.first['id'] as int?) : null;
          _cargando = false;
        });
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'transferencia_page.cargar',
        error: e,
        stackTrace: st,
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

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;

    if (_cuentaOrigenId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione cuenta de origen')),
      );
      return;
    }

    if (_cuentaDestinoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione cuenta de destino')),
      );
      return;
    }

    if (_medioPagoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione método de pago')),
      );
      return;
    }

    setState(() => _guardando = true);

    try {
      final monto = double.tryParse(
        _montoCtrl.text.trim().replaceAll(',', '.'),
      ) ?? 0.0;

      // Verificar comisión de cuenta destino ANTES de crear transferencia
      final cuentaDestino = _cuentas.firstWhere((c) => c.id == _cuentaDestinoId);
      final comisionPorcentaje = cuentaDestino.comisionPorcentaje ?? 0.0;
      final montoComision = comisionPorcentaje > 0 ? monto * (comisionPorcentaje / 100) : 0.0;
      
      double? montoComisionFinal = montoComision;
      String? observacionComision;
      
      // Si hay comisión, mostrar modal
      if (montoComision > 0) {
        final resultado = await showDialog<Map<String, dynamic>?>(
          context: context,
          builder: (context) => _DialogComisionTransferencia(
            comision: montoComision,
            cuenta: cuentaDestino,
            montoTransferido: monto,
            observacionMovimiento: _observacionCtrl.text.trim(),
          ),
        );
        
        if (resultado == null) {
          // Usuario canceló
          setState(() => _guardando = false);
          return;
        }
        
        montoComisionFinal = resultado['monto'] as double?;
        observacionComision = resultado['observacion'] as String?;
      } else {
        // Sin comisión — mostrar modal de confirmación simple
        final cuentaOrigenPrevia = _cuentas.firstWhere((c) => c.id == _cuentaOrigenId);
        final medioPago = _metodosPago.firstWhere(
          (m) => m['id'] == _medioPagoId,
          orElse: () => {},
        );
        final medioPagoNombre = medioPago['nombre'] as String? ?? 'Sin especificar';
        final observacion = _observacionCtrl.text.trim();

        final confirmar = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.swap_horiz, size: 48, color: AppColors.info),
            title: const Text('Confirmar Transferencia'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildResultRow('Origen:', cuentaOrigenPrevia.nombre),
                _buildResultRow('Destino:', cuentaDestino.nombre),
                _buildResultRow('Medio de pago:', medioPagoNombre),
                if (observacion.isNotEmpty)
                  _buildResultRow('Observación:', observacion),
                const Divider(),
                _buildResultRow('Monto:', Format.money(monto), isBold: true),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.check),
                label: const Text('Confirmar'),
              ),
            ],
          ),
        );

        if (confirmar != true) {
          setState(() => _guardando = false);
          return;
        }
      }

      final transferenciaId = await _transferenciaService.crear(
        cuentaOrigenId: _cuentaOrigenId!,
        cuentaDestinoId: _cuentaDestinoId!,
        monto: monto,
        medioPagoId: _medioPagoId!,
        observacion: _observacionCtrl.text.trim().isEmpty
            ? null
            : _observacionCtrl.text.trim(),
        montoComisionOverride: montoComisionFinal,
        observacionComisionOverride: observacionComision,
      );

      if (!mounted) return;
      
      // FASE 22.3: Mostrar modal de resultado exitoso
      final cuentaOrigen = _cuentas.firstWhere((c) => c.id == _cuentaOrigenId);
      final cuentaDestinoResultado = _cuentas.firstWhere((c) => c.id == _cuentaDestinoId);
      
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.check_circle, size: 64, color: AppColors.ingreso),
          title: const Text('Transferencia Exitosa'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ID: $transferenciaId', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(height: 16),
              _buildResultRow('Origen:', cuentaOrigen.nombre),
              _buildResultRow('Destino:', cuentaDestinoResultado.nombre),
              _buildResultRow('Monto:', Format.money(monto)),
              if (montoComisionFinal != null && montoComisionFinal > 0)
                _buildResultRow('Comisión:', Format.money(montoComisionFinal), isHighlight: true),
              const Divider(),
              _buildResultRow(
                'Total debitado:',
                Format.money(monto + (montoComisionFinal ?? 0)),
                isBold: true,
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context); // Cerrar modal
                Navigator.pop(context, true); // Cerrar página de transferencia
              },
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'transferencia_page.guardar',
        error: e,
        stackTrace: st,
      );

      if (!mounted) return;
      
      // FASE 22.3: Mostrar modal de error
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.error, size: 64, color: AppColors.egreso),
          title: const Text('Error en Transferencia'),
          content: Text(
            'No se pudo completar la transferencia:\n\n${e.toString()}',
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(backgroundColor: AppColors.egreso),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }
  
  Widget _buildResultRow(String label, String value, {bool isBold = false, bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: isHighlight ? AppColors.advertencia : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nueva Transferencia'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _cuentas.length < 2
              ? _buildInsuficientesCuentas()
              : ResponsiveContainer(
                  maxWidth: 800,
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.all(16.0),
                      children: [
                      // Cuenta origen
                      DropdownButtonFormField<int>(
                        value: _cuentaOrigenId,
                        decoration: const InputDecoration(
                          labelText: 'Cuenta de origen *',
                          prefixIcon: Icon(Icons.account_balance_wallet),
                          border: OutlineInputBorder(),
                        ),
                        items: _cuentas
                            .map((cuenta) => DropdownMenuItem(
                                  value: cuenta.id,
                                  child: Text(
                                    '${cuenta.nombre} (${cuenta.tipo})',
                                  ),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() => _cuentaOrigenId = value);
                        },
                        validator: (value) {
                          if (value == null) {
                            return 'Seleccione cuenta de origen';
                          }
                          return null;
                        },
                      ),
                      
                      // FASE 22.3: Mostrar saldo de cuenta origen
                      if (_cuentaOrigenId != null) ...[
                        const SizedBox(height: 8),
                        FutureBuilder<double>(
                          future: _cuentaService.obtenerSaldo(_cuentaOrigenId!),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Padding(
                                padding: EdgeInsets.only(left: 48),
                                child: Text(
                                  'Calculando saldo...',
                                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                                ),
                              );
                            }
                            final saldo = snapshot.data!;
                            return Padding(
                              padding: const EdgeInsets.only(left: 48),
                              child: Text(
                                'Saldo actual: ${Format.money(saldo)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: saldo >= 0 ? AppColors.ingreso : AppColors.egreso,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 16),

                      // Icono de flecha
                      const Center(
                        child: Icon(Icons.arrow_downward, size: 32, color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 16),

                      // Cuenta destino
                      DropdownButtonFormField<int>(
                        value: _cuentaDestinoId,
                        decoration: const InputDecoration(
                          labelText: 'Cuenta de destino *',
                          prefixIcon: Icon(Icons.account_balance),
                          border: OutlineInputBorder(),
                        ),
                        items: _cuentas
                            .where((cuenta) => cuenta.id != _cuentaOrigenId)
                            .map((cuenta) => DropdownMenuItem(
                                  value: cuenta.id,
                                  child: Text(
                                    '${cuenta.nombre} (${cuenta.tipo})',
                                  ),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() => _cuentaDestinoId = value);
                        },
                        validator: (value) {
                          if (value == null) {
                            return 'Seleccione cuenta de destino';
                          }
                          if (value == _cuentaOrigenId) {
                            return 'No puede transferir a la misma cuenta';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Monto
                      TextFormField(
                        controller: _montoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Monto *',
                          prefixText: '\$ ',
                          prefixIcon: Icon(Icons.attach_money),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese el monto';
                          }
                          final monto = double.tryParse(value.trim().replaceAll(',', '.'));
                          if (monto == null || monto <= 0) {
                            return 'Monto inválido';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Método de pago
                      DropdownButtonFormField<int>(
                        value: _medioPagoId,
                        decoration: const InputDecoration(
                          labelText: 'Método de pago *',
                          prefixIcon: Icon(Icons.payment),
                          border: OutlineInputBorder(),
                        ),
                        items: _metodosPago
                            .map((mp) => DropdownMenuItem(
                                  value: mp['id'] as int,
                                  child: Text(mp['descripcion'] as String),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() => _medioPagoId = value);
                        },
                      ),
                      const SizedBox(height: 16),

                      // Observación
                      TextFormField(
                        controller: _observacionCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Observación',
                          hintText: 'Notas adicionales (opcional)',
                          prefixIcon: Icon(Icons.note),
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 24),

                      // Información
                      const Card(
                        color: AppColors.infoDim,
                        child: Padding(
                          padding: EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.info_outline, color: AppColors.infoLight),
                                  SizedBox(width: 8),
                                  Text(
                                    'Información',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.infoLight,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 8),
                              Text(
                                '• La transferencia genera 2 movimientos vinculados.\n'
                                '• NO afecta el saldo total del sistema.\n'
                                '• Solo mueve dinero entre cuentas de la misma unidad.',
                                style: TextStyle(fontSize: 13, color: AppColors.infoLight),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Botones
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _guardando ? null : () => Navigator.pop(context),
                              child: const Text('Cancelar'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _guardando ? null : _guardar,
                              child: _guardando
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Text('Transferir'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
    );
  }

  Widget _buildInsuficientesCuentas() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber, size: 64, color: AppColors.advertencia),
            const SizedBox(height: 16),
            const Text(
              'Cuentas insuficientes',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Necesitas al menos 2 cuentas activas para realizar transferencias.\n\n'
              'Cuentas disponibles: ${_cuentas.length}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Volver'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog para confirmar comisión bancaria en transferencias
class _DialogComisionTransferencia extends StatefulWidget {
  final double comision;
  final CuentaFondos cuenta;
  final double montoTransferido;
  final String observacionMovimiento;

  const _DialogComisionTransferencia({
    required this.comision,
    required this.cuenta,
    required this.montoTransferido,
    required this.observacionMovimiento,
  });

  @override
  State<_DialogComisionTransferencia> createState() => _DialogComisionTransferenciaState();
}

class _DialogComisionTransferenciaState extends State<_DialogComisionTransferencia> {
  late TextEditingController _montoController;
  late TextEditingController _observacionController;
  
  @override
  void initState() {
    super.initState();
    _montoController = TextEditingController(text: widget.comision.toStringAsFixed(2));
    
    // Precargar observación con prefijo
    final observacionPrefijo = widget.observacionMovimiento.isNotEmpty
        ? 'Comisión bancaria: ${widget.observacionMovimiento}'
        : 'Comisión bancaria';
    _observacionController = TextEditingController(text: observacionPrefijo);
  }

  @override
  void dispose() {
    _montoController.dispose();
    _observacionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final porcentaje = widget.cuenta.comisionPorcentaje ?? 0.0;
    
    return AlertDialog(
      icon: const Icon(Icons.account_balance, size: 48, color: AppColors.advertencia),
      title: const Text('Comisión Bancaria'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'La cuenta "${widget.cuenta.nombre}" cobra comisión del $porcentaje%.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            
            // Info de cálculo
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.info.withValues(alpha: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Monto transferido:'),
                      Text(
                        Format.money(widget.montoTransferido),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Porcentaje comisión:'),
                      Text(
                        '$porcentaje%',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Comisión calculada:'),
                      Text(
                        Format.money(widget.comision),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.advertencia,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 20),
            const Text(
              'Monto de comisión (editable):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _montoController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixText: '\$ ',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
            
            const SizedBox(height: 16),
            const Text(
              'Observación (opcional):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _observacionController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Detalles adicionales...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: AppColors.bgElevated,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final montoEditado = double.tryParse(_montoController.text) ?? widget.comision;
            final observacion = _observacionController.text.trim();
            
            Navigator.pop(context, {
              'monto': montoEditado,
              'observacion': observacion.isEmpty ? null : observacion,
            });
          },
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.advertencia,
          ),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}
