import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../../../features/shared/services/compromisos_service.dart';
import '../../../features/shared/state/app_settings.dart';
import '../../../data/dao/db.dart';
import '../services/categoria_movimiento_service.dart';
import '../services/cuenta_service.dart';
import '../../shared/widgets/responsive_container.dart';
import 'dart:io';

/// Página para confirmar un movimiento esperado como real.
/// 
/// Convierte un movimiento proyectado en un registro real en la base de datos.
/// Si [unidadAcuerdo] es 'LTS', el formulario solicita litros + precio/lt
/// y calcula el monto ARS automáticamente.
class ConfirmarMovimientoPage extends StatefulWidget {
  final int compromisoId;
  final DateTime fechaVencimiento;
  final double montoSugerido;
  final String tipo;
  final String categoria;
  final int? numeroCuota; // Número de cuota a confirmar
  final String unidadAcuerdo; // 'ARS' (default) o 'LTS'
  
  const ConfirmarMovimientoPage({
    super.key,
    required this.compromisoId,
    required this.fechaVencimiento,
    required this.montoSugerido,
    required this.tipo,
    required this.categoria,
    this.numeroCuota,
    this.unidadAcuerdo = 'ARS',
  });

  @override
  State<ConfirmarMovimientoPage> createState() => _ConfirmarMovimientoPageState();
}

class _ConfirmarMovimientoPageState extends State<ConfirmarMovimientoPage> {
  final _formKey = GlobalKey<FormState>();
  final _compromisosService = CompromisosService.instance;
  final _cuentaService = CuentaService();
  
  // Controllers
  final _montoController = TextEditingController();
  final _observacionesController = TextEditingController();
  // Campos exclusivos para acuerdos LTS (combustible)
  final _litrosCtrl = TextEditingController();
  final _precioLitroCtrl = TextEditingController();
  
  // Form values
  DateTime _fechaReal = DateTime.now();
  int? _medioPagoId;
  int? _cuentaId; // Cuenta desde la cual se paga
  double? _montoArsCalculado; // solo usado cuando unidadAcuerdo == 'LTS'
  
  // Adjunto (puede ser imagen o PDF)
  File? _archivoLocal;
  String? _archivoNombre;
  String? _archivoTipo;
  
  // Estado
  bool _isSubmitting = false;
  List<Map<String, dynamic>> _mediosPago = [];
  List<Map<String, dynamic>> _cuentas = [];
  Map<String, dynamic>? _compromiso;
  String? _categoriaNombre;
  
  @override
  void initState() {
    super.initState();
    _fechaReal = widget.fechaVencimiento;
    if (widget.unidadAcuerdo == 'LTS') {
      // Para acuerdos en litros, la sugerencia es la cantidad de litros esperados
      _litrosCtrl.text = widget.montoSugerido.toStringAsFixed(2);
      _litrosCtrl.addListener(_recalcularMonto);
      _precioLitroCtrl.addListener(_recalcularMonto);
    } else {
      _montoController.text = widget.montoSugerido.toString();
    }
    _cargarDatos();
  }

  void _recalcularMonto() {
    final litros = double.tryParse(_litrosCtrl.text.replaceAll(',', '.'));
    final precio = double.tryParse(_precioLitroCtrl.text.replaceAll(',', '.'));
    setState(() {
      _montoArsCalculado = (litros != null && precio != null && litros > 0 && precio > 0)
          ? litros * precio
          : null;
    });
  }

  @override
  void dispose() {
    _montoController.dispose();
    _observacionesController.dispose();
    _litrosCtrl.dispose();
    _precioLitroCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    try {
      final db = await AppDatabase.instance();
      final settings = Provider.of<AppSettings>(context, listen: false);
      final unidadGestionId = settings.unidadGestionActivaId;
      
      // Cargar medios de pago
      final medios = await db.query('metodos_pago', orderBy: 'descripcion');
      
      // Cargar cuentas activas de la unidad actual
      List<Map<String, dynamic>> cuentas = [];
      if (unidadGestionId != null) {
        final cuentasResult = await _cuentaService.listarPorUnidad(unidadGestionId);
        cuentas = cuentasResult.map((c) => c.toMap()).toList();
      }
      
      // Cargar compromiso
      final compromiso = await _compromisosService.obtenerCompromiso(widget.compromisoId);
      
      // Cargar nombre de categoría
      String? catNombre;
      if (widget.categoria.isNotEmpty) {
        catNombre = await CategoriaMovimientoService.obtenerNombrePorCodigo(widget.categoria);
      }
      
      setState(() {
        _mediosPago = medios;
        _cuentas = cuentas;
        _compromiso = compromiso;
        _categoriaNombre = catNombre;
        if (_mediosPago.isNotEmpty) {
          _medioPagoId = _mediosPago.first['id'] as int;
        }
        if (_cuentas.isNotEmpty) {
          _cuentaId = _cuentas.first['id'] as int;
        }
      });
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'confirmar_movimiento.cargar',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _seleccionarArchivo(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final file = File(pickedFile.path);
        final size = await file.length();
        
        // Validar tamaño (25MB)
        if (size > 25 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('El archivo supera el límite de 25MB'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        setState(() {
          _archivoLocal = file;
          _archivoNombre = pickedFile.name;
          _archivoTipo = 'image';
        });
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'confirmar_movimiento.seleccionar_archivo',
        error: e,
        stackTrace: st,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al seleccionar archivo. Intente nuevamente.')),
        );
      }
    }
  }

  Future<void> _seleccionarPDF() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final size = await file.length();
        
        // Validar tamaño (25MB)
        if (size > 25 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('El archivo supera el límite de 25MB'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        setState(() {
          _archivoLocal = file;
          _archivoNombre = result.files.single.name;
          _archivoTipo = 'pdf';
        });
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'confirmar_movimiento.seleccionar_pdf',
        error: e,
        stackTrace: st,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al seleccionar PDF. Intente nuevamente.')),
        );
      }
    }
  }

  Future<void> _confirmar() async {
    if (!mounted) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_medioPagoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná un medio de pago')),
      );
      return;
    }

    if (_cuentaId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una cuenta')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final settings = context.read<AppSettings>();
      final unidadGestionId = settings.unidadGestionActivaId;
      
      if (unidadGestionId == null) {
        throw StateError('No hay unidad de gestión activa');
      }

      // Calcular monto ARS y campos LTS según la unidad del acuerdo
      double monto;
      double? cantidadLitros;
      double? precioLitroArs;

      if (widget.unidadAcuerdo == 'LTS') {
        final litros = double.tryParse(_litrosCtrl.text.replaceAll(',', '.'));
        final precio = double.tryParse(_precioLitroCtrl.text.replaceAll(',', '.'));
        if (litros == null || litros <= 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ingresá una cantidad de litros válida')),
            );
          }
          setState(() => _isSubmitting = false);
          return;
        }
        if (precio == null || precio <= 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ingresá un precio por litro válido')),
            );
          }
          setState(() => _isSubmitting = false);
          return;
        }
        cantidadLitros = litros;
        precioLitroArs = precio;
        monto = litros * precio;
      } else {
        monto = double.parse(_montoController.text);
      }

      // H.6: Operación transaccional — crea movimiento + actualiza cuota + incrementa contador
      await _compromisosService.confirmarCuota(
        compromisoId: widget.compromisoId,
        disciplinaId: unidadGestionId,
        cuentaId: _cuentaId!,
        tipo: widget.tipo,
        categoria: widget.categoria,
        monto: monto,
        medioPagoId: _medioPagoId!,
        fechaReal: _fechaReal,
        fechaVencimiento: widget.fechaVencimiento,
        numeroCuota: widget.numeroCuota ?? 0,
        unidadGestionId: unidadGestionId,
        observacion: _observacionesController.text.trim().isNotEmpty
            ? _observacionesController.text.trim()
            : null,
        archivoLocalPath: _archivoLocal?.path,
        archivoNombre: _archivoNombre,
        archivoTipo: _archivoTipo,
        cantidadLitros: cantidadLitros,
        precioLitroArs: precioLitroArs,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Movimiento confirmado exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'confirmar_movimiento.confirmar',
        error: e,
        stackTrace: st,
      );

      if (!mounted) return;
      setState(() => _isSubmitting = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Error al confirmar. Intente nuevamente.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirmar Movimiento'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          if (!_isSubmitting)
            TextButton(
              onPressed: _confirmar,
              child: const Text(
                'CONFIRMAR',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: ResponsiveContainer(
        maxWidth: 800,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              // Info del compromiso
              if (_compromiso != null)
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Compromiso',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(_compromiso!['nombre'] as String? ?? ''),
                        Text('Tipo: ${widget.tipo}'),
                        Text('Categoría: ${_categoriaNombre ?? widget.categoria}'),
                        Text(
                          'Vencimiento esperado: ${DateFormat('dd/MM/yyyy').format(widget.fechaVencimiento)}',
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              
              // Fecha real
              ListTile(
                title: const Text('Fecha real del movimiento *'),
                subtitle: Text(DateFormat('dd/MM/yyyy').format(_fechaReal)),
                leading: const Icon(Icons.calendar_today),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: const BorderSide(color: Colors.grey),
                ),
                onTap: _isSubmitting ? null : () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _fechaReal,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) {
                    setState(() => _fechaReal = picked);
                  }
                },
              ),
              const SizedBox(height: 16),
              
              // Monto — bloque condicional según unidad del acuerdo
              if (widget.unidadAcuerdo == 'LTS') ...[
                // Banner informativo
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.local_gas_station, color: Colors.blue.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Acuerdo en litros — ingresá la cantidad entregada y el precio del día. '
                          'El monto en pesos se calcula automáticamente.',
                          style: TextStyle(color: Colors.blue.shade800, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Litros entregados
                TextFormField(
                  controller: _litrosCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,3}')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Litros entregados *',
                    hintText: 'Ej: 10',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.local_gas_station),
                    suffixText: 'lts',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Requerido';
                    final val = double.tryParse(v.replaceAll(',', '.'));
                    if (val == null || val <= 0) return 'Debe ser mayor a 0';
                    return null;
                  },
                  enabled: !_isSubmitting,
                ),
                const SizedBox(height: 12),
                // Precio por litro
                TextFormField(
                  controller: _precioLitroCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Precio por litro *',
                    hintText: 'Ej: 1897',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                    prefixText: '\$ ',
                    suffixText: '/lt',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Requerido';
                    final val = double.tryParse(v.replaceAll(',', '.'));
                    if (val == null || val <= 0) return 'Debe ser mayor a 0';
                    return null;
                  },
                  enabled: !_isSubmitting,
                ),
                const SizedBox(height: 12),
                // Monto ARS calculado (read-only)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  decoration: BoxDecoration(
                    color: _montoArsCalculado != null
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _montoArsCalculado != null
                          ? Colors.green.shade300
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.calculate,
                        color: _montoArsCalculado != null
                            ? Colors.green.shade700
                            : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Monto a registrar (en pesos)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _montoArsCalculado != null
                                ? '\$ ${_montoArsCalculado!.toStringAsFixed(2)}'
                                : 'Completá litros y precio',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _montoArsCalculado != null
                                  ? Colors.green.shade800
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Flujo ARS estándar
                TextFormField(
                  controller: _montoController,
                  decoration: const InputDecoration(
                    labelText: 'Monto real *',
                    hintText: 'Ingresá el monto efectivo',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                  ],
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Requerido';
                    }
                    final monto = double.tryParse(v);
                    if (monto == null || monto <= 0) {
                      return 'Debe ser mayor a cero';
                    }
                    return null;
                  },
                  enabled: !_isSubmitting,
                ),
              ],
              const SizedBox(height: 16),
              
              // Medio de pago
              DropdownButtonFormField<int>(
                value: _medioPagoId,
                decoration: const InputDecoration(
                  labelText: 'Medio de pago *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.payment),
                ),
                items: _mediosPago.map((m) {
                  return DropdownMenuItem(
                    value: m['id'] as int,
                    child: Text(m['descripcion'] as String),
                  );
                }).toList(),
                onChanged: _isSubmitting ? null : (v) {
                  setState(() => _medioPagoId = v);
                },
                validator: (v) {
                  if (v == null) {
                    return 'Seleccioná un medio de pago';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Cuenta (fondo)
              DropdownButtonFormField<int>(
                value: _cuentaId,
                decoration: const InputDecoration(
                  labelText: 'Cuenta (fondo) *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.account_balance_wallet),
                ),
                items: _cuentas.map((c) {
                  return DropdownMenuItem(
                    value: c['id'] as int,
                    child: Text(c['nombre'] as String),
                  );
                }).toList(),
                onChanged: _isSubmitting ? null : (v) {
                  setState(() => _cuentaId = v);
                },
                validator: (v) {
                  if (v == null) {
                    return 'Seleccioná una cuenta';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Observaciones
              TextFormField(
                controller: _observacionesController,
                decoration: const InputDecoration(
                  labelText: 'Observaciones (opcional)',
                  hintText: 'Notas adicionales...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 3,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: 16),
              
              // Adjuntar comprobante
              const Text(
                'Adjuntar comprobante (opcional)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isSubmitting
                          ? null
                          : () => _seleccionarArchivo(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Tomar foto'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isSubmitting
                          ? null
                          : () => _seleccionarArchivo(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Galería'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _seleccionarPDF,
                icon: const Icon(Icons.picture_as_pdf, color: Colors.red),
                label: const Text('Seleccionar PDF'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                ),
              ),
              if (_archivoLocal != null) ...[
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file, color: Colors.blue),
                    title: Text(_archivoNombre ?? 'Archivo adjunto'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _isSubmitting
                          ? null
                          : () {
                              setState(() {
                                _archivoLocal = null;
                                _archivoNombre = null;
                              });
                            },
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              
              // Botón confirmar
              ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _confirmar,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle),
                label: Text(_isSubmitting ? 'Confirmando...' : 'Confirmar Movimiento'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
