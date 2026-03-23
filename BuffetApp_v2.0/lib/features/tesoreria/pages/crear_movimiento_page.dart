import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../shared/services/movimiento_service.dart';
import '../../shared/services/attachment_service.dart';
import '../../shared/services/error_handler.dart';
import '../../shared/services/plantel_service.dart';
import '../../shared/utils/category_icon_helper.dart';
import '../../shared/format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../layout/erp_layout.dart';
import '../../../widgets/app_header.dart';
import '../../../data/dao/db.dart';
import '../../../data/dao/evento_dao.dart';
import '../../../domain/models.dart';
import '../../shared/state/app_settings.dart';
import '../../shared/widgets/responsive_container.dart';
import '../services/cuenta_service.dart';

/// Pantalla para crear o editar un movimiento financiero (ingreso/egreso)
class CrearMovimientoPage extends StatefulWidget {
  final Map<String, dynamic>? movimientoExistente;
  final int? unidadGestionIdInicial;
  final String? eventoIdInicial;
  final int? cuentaIdInicial;
  final String? tipoInicial;
  final String? categoriaInicial;
  final double? montoInicial;
  final String? descripcionInicial;
  final int? eventoCdmIdInicial;
  // Parámetros para adhesiones de combustible (unidad LTS)
  final String unidadAcuerdo;
  final double? cantidadLitrosInicial;
  final double? precioLitroInicial;
  
  const CrearMovimientoPage({
    super.key,
    this.movimientoExistente,
    this.unidadGestionIdInicial,
    this.eventoIdInicial,
    this.cuentaIdInicial,
    this.tipoInicial,
    this.categoriaInicial,
    this.montoInicial,
    this.descripcionInicial,
    this.eventoCdmIdInicial,
    this.unidadAcuerdo = 'ARS',
    this.cantidadLitrosInicial,
    this.precioLitroInicial,
  });

  @override
  State<CrearMovimientoPage> createState() => _CrearMovimientoPageState();
}

class _CrearMovimientoPageState extends State<CrearMovimientoPage> {
  final _formKey = GlobalKey<FormState>();
  final _montoCtrl = TextEditingController();
  final _obsCtrl = TextEditingController();
  // Campos exclusivos para acuerdos en litros (combustible)
  final _litrosCtrl = TextEditingController();
  final _precioLitroCtrl = TextEditingController();
  double? _montoArsCalculado;
  
  String _tipo = 'INGRESO';
  String? _codigoCategoria;
  int? _medioPagoId;
  int? _cuentaId;
  int? _entidadPlantelId;
  int? _eventoCdmId;
  File? _attachmentFile;
  
  List<Map<String, dynamic>> _metodosPago = [];
  List<Map<String, dynamic>> _categorias = [];
  List<CuentaFondos> _cuentas = [];
  List<Map<String, dynamic>> _entidadesPlantel = [];
  List<Map<String, dynamic>> _eventosCdmMes = [];
  
  bool _cargando = true;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    
    // FASE 22.2: Si se pasan parámetros iniciales, usarlos
    if (widget.cuentaIdInicial != null) {
      _cuentaId = widget.cuentaIdInicial;
    }
    if (widget.tipoInicial != null) {
      _tipo = widget.tipoInicial!;
    }
    if (widget.categoriaInicial != null) {
      _codigoCategoria = widget.categoriaInicial;
    }
    if (widget.montoInicial != null) {
      _montoCtrl.text = widget.montoInicial!.toStringAsFixed(2);
    }
    // Pre-cargar campos LTS si corresponde
    if (widget.unidadAcuerdo == 'LTS') {
      if (widget.cantidadLitrosInicial != null) {
        _litrosCtrl.text = widget.cantidadLitrosInicial!.toStringAsFixed(2);
      }
      if (widget.precioLitroInicial != null) {
        _precioLitroCtrl.text = widget.precioLitroInicial!.toStringAsFixed(2);
      }
      _litrosCtrl.addListener(_recalcularMontoLts);
      _precioLitroCtrl.addListener(_recalcularMontoLts);
      _recalcularMontoLts();
    }
    if (widget.descripcionInicial != null) {
      _obsCtrl.text = widget.descripcionInicial!;
    }
    if (widget.eventoCdmIdInicial != null) {
      _eventoCdmId = widget.eventoCdmIdInicial;
    }
    
    // Si es edición, pre-cargar los datos
    if (widget.movimientoExistente != null) {
      final mov = widget.movimientoExistente!;
      _tipo = mov['tipo'] as String? ?? 'INGRESO';
      _codigoCategoria = mov['categoria'] as String?;
      _medioPagoId = mov['medio_pago_id'] as int?;
      _cuentaId = mov['cuenta_id'] as int?;
      _entidadPlantelId = mov['entidad_plantel_id'] as int?;
      _eventoCdmId = mov['evento_cdm_id'] as int?;
      _montoCtrl.text = (mov['monto'] as num?)?.toString() ?? '';
      _obsCtrl.text = mov['observacion'] as String? ?? '';
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) => _cargarDatos());
  }

  Future<void> _cargarDatos() async {
    try {
      final db = await AppDatabase.instance();
      final settings = context.read<AppSettings>();
      final unidadId = settings.disciplinaActivaId;
      
      // Cargar métodos de pago
      final metodos = await db.query('metodos_pago', orderBy: 'id ASC');
      
      // Cargar categorías para el tipo inicial
      final cats = await db.query(
        'categoria_movimiento',
        where: "(tipo = ? OR tipo = 'AMBOS') AND activa = 1",
        whereArgs: [_tipo],
        orderBy: 'nombre ASC',
      );
      
      // Cargar cuentas activas de la unidad
      List<CuentaFondos> cuentas = [];
      if (unidadId != null) {
        final cuentaService = CuentaService();
        cuentas = await cuentaService.listarPorUnidad(unidadId, soloActivas: true);
      }
      
      // Cargar entidades del plantel (jugadores y staff)
      final entidades = await PlantelService.instance.listarEntidades(soloActivos: true);
      
      // Cargar eventos CDM de la unidad (para asociar al movimiento)
      final eventosCdm = unidadId != null
          ? await EventoDao.getEventosByUnidad(unidadId)
          : <Map<String, dynamic>>[];
      
      if (!mounted) return;
      
      setState(() {
        _metodosPago = metodos;
        _categorias = cats;
        _cuentas = cuentas;
        _entidadesPlantel = entidades;
        _eventosCdmMes = eventosCdm;
        _medioPagoId = metodos.isNotEmpty ? metodos.first['id'] as int? : null;
        // FASE 22.2: Mantener cuentaId inicial si se pasó, sino usar primera cuenta
        if (_cuentaId == null || !cuentas.any((c) => c.id == _cuentaId)) {
          _cuentaId = cuentas.isNotEmpty ? cuentas.first.id : null;
        }
        _cargando = false;
      });
    } catch (e, st) {
      await ErrorHandler.instance.handle(
        scope: 'tesoreria.cargar_formulario',
        error: e,
        stackTrace: st,
        context: mounted ? context : null,
      );
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }
  
  Future<void> _cargarCategorias() async {
    try {
      final db = await AppDatabase.instance();
      final cats = await db.query(
        'categoria_movimiento',
        where: "(tipo = ? OR tipo = 'AMBOS') AND activa = 1",
        whereArgs: [_tipo],
        orderBy: 'nombre ASC',
      );
      
      if (!mounted) return;
      
      setState(() {
        _categorias = cats;
        // Limpiar categoría si ya no es válida
        if (_codigoCategoria != null) {
          final esValida = _categorias.any((c) => c['codigo'] == _codigoCategoria);
          if (!esValida) _codigoCategoria = null;
        }
      });
    } catch (e) {
      // Error silencioso
      if (mounted) {
        setState(() => _categorias = []);
      }
    }
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    
    final settings = context.read<AppSettings>();
    final unidadGestionId = settings.unidadGestionActivaId;
    final disciplinaId = settings.disciplinaActivaId ?? unidadGestionId;
    
    if (unidadGestionId == null || disciplinaId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una Unidad de Gestión primero')),
      );
      return;
    }
    
    if (_codigoCategoria == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una categoría')),
      );
      return;
    }
    
    if (_cuentaId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una cuenta')),
      );
      return;
    }
    
    setState(() => _guardando = true);
    
    try {
      final svc = EventoMovimientoService();
      final attachmentSvc = AttachmentService();
      
      // Manejar archivo adjunto
      String? archivoLocalPath;
      String? archivoNombre;
      String? archivoTipo;
      int? archivoSize;
      
      if (_attachmentFile != null) {
        final savedAttachment = await attachmentSvc.saveAttachment(_attachmentFile!);
        archivoLocalPath = savedAttachment['archivo_local_path'];
        archivoNombre = savedAttachment['archivo_nombre'];
        archivoTipo = savedAttachment['archivo_tipo'];
        archivoSize = savedAttachment['archivo_size'];
      }
      
      // Para acuerdos LTS: calcular monto ARS a partir de litros × precio/lt
      double monto;
      double? cantidadLitros;
      double? precioLitroArs;
      if (widget.unidadAcuerdo == 'LTS') {
        final litros = double.tryParse(_litrosCtrl.text.trim().replaceAll(',', '.'));
        final precio = double.tryParse(_precioLitroCtrl.text.trim().replaceAll(',', '.'));
        if (litros == null || litros <= 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ingresá una cantidad de litros válida')),
            );
          }
          setState(() => _guardando = false);
          return;
        }
        if (precio == null || precio <= 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ingresá un precio por litro válido')),
            );
          }
          setState(() => _guardando = false);
          return;
        }
        cantidadLitros = litros;
        precioLitroArs = precio;
        monto = litros * precio;
      } else {
        monto = double.parse(_montoCtrl.text.trim().replaceAll(',', '.'));
      }

      if (widget.movimientoExistente != null) {
        // Actualizar movimiento existente
        final movId = widget.movimientoExistente!['id'] as int;
        await svc.actualizar(
          id: movId,
          disciplinaId: disciplinaId,
          cuentaId: _cuentaId!,
          eventoId: settings.eventoActivoId,
          tipo: _tipo,
          categoria: _codigoCategoria!,
          monto: monto,
          medioPagoId: _medioPagoId!,
          unidadGestionId: unidadGestionId,
          observacion: _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text.trim(),
          archivoLocalPath: archivoLocalPath,
          archivoNombre: archivoNombre,
          archivoTipo: archivoTipo,
          archivoSize: archivoSize,
          entidadPlantelId: _entidadPlantelId,
          eventoCdmId: _eventoCdmId,
        );
        // Si es LTS, actualizar también la cuota en compromiso_cuotas
        if (widget.unidadAcuerdo == 'LTS' && cantidadLitros != null && precioLitroArs != null) {
          final db = await AppDatabase.instance();
          await db.rawUpdate('''
            UPDATE compromiso_cuotas
            SET monto_real = ?, cantidad_litros = ?, precio_litro_ars = ?, updated_ts = ?
            WHERE movimiento_id = ?
          ''', [monto, cantidadLitros, precioLitroArs, DateTime.now().millisecondsSinceEpoch, movId]);
        }
      } else {
        // Crear nuevo movimiento
        await svc.crear(
          disciplinaId: disciplinaId,
          cuentaId: _cuentaId!,
          eventoId: settings.eventoActivoId,
          tipo: _tipo,
          categoria: _codigoCategoria!,
          monto: monto,
          medioPagoId: _medioPagoId!,
          unidadGestionId: unidadGestionId,
          observacion: _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text.trim(),
          archivoLocalPath: archivoLocalPath,
          archivoNombre: archivoNombre,
          archivoTipo: archivoTipo,
          archivoSize: archivoSize,
          entidadPlantelId: _entidadPlantelId,
          eventoCdmId: _eventoCdmId,
        );
        
        // Lógica de comisión semiautomática (solo para movimientos nuevos)
        await _verificarComision(_cuentaId!, monto, disciplinaId, settings.eventoActivoId);
      }
      
      if (!mounted) return;

      // Construir datos del modal de confirmación
      final categoriaNombre = _categorias
          .where((c) => c['codigo'] == _codigoCategoria)
          .map((c) => c['nombre'] as String?)
          .firstOrNull ?? _codigoCategoria ?? '–';
      final medioPagoNombre = _metodosPago
          .where((m) => m['id'] == _medioPagoId)
          .map((m) => m['nombre'] as String?)
          .firstOrNull ?? '–';
      final cuentaNombre = _cuentas
          .where((c) => c.id == _cuentaId)
          .map((c) => c.nombre)
          .firstOrNull ?? '–';
      final observacion = _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text.trim();
      final esEdicion = widget.movimientoExistente != null;

      // Guardar el Navigator antes del showDialog para poder popear
      // la página desde dentro del callback del botón sin problemas de contexto.
      final nav = Navigator.of(context);

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.check_circle, color: AppColors.ingreso, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  esEdicion ? 'Movimiento Actualizado' : 'Movimiento Creado',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetalleFila(
                'Tipo',
                _tipo == 'INGRESO' ? 'Ingreso' : 'Egreso',
                color: _tipo == 'INGRESO' ? AppColors.ingreso : AppColors.egreso,
              ),
              _buildDetalleFila('Monto', Format.money(monto)),
              _buildDetalleFila('Categoría', categoriaNombre),
              _buildDetalleFila('Medio de Pago', medioPagoNombre),
              _buildDetalleFila('Cuenta', cuentaNombre),
              if (observacion != null) _buildDetalleFila('Observación', observacion),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx); // cierra el diálogo
                nav.pop(true);      // cierra la página y devuelve true al caller
              },
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      await ErrorHandler.instance.handle(
        scope: 'tesoreria.crear_movimiento',
        error: e,
        stackTrace: st,
        context: mounted ? context : null,
        userMessage: 'No se pudo guardar el movimiento',
        showDialog: true,
      );
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Widget _buildDetalleFila(String label, String valor, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              valor,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _seleccionarArchivo() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Cámara'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf),
              title: const Text('Archivo PDF'),
              onTap: () => Navigator.pop(context, 'pdf'),
            ),
            if (_attachmentFile != null)
              ListTile(
                leading: const Icon(Icons.delete, color: AppColors.egreso),
                title: const Text('Eliminar'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    
    if (result == null) return;
    
    try {
      final attachmentSvc = AttachmentService();
      
      if (result == 'remove') {
        setState(() => _attachmentFile = null);
      } else if (result == 'gallery') {
        final file = await attachmentSvc.pickFromGallery();
        if (file != null) setState(() => _attachmentFile = file);
      } else if (result == 'camera') {
        final file = await attachmentSvc.pickFromCamera();
        if (file != null) setState(() => _attachmentFile = file);
      } else if (result == 'pdf') {
        final file = await attachmentSvc.pickPdf();
        if (file != null) setState(() => _attachmentFile = file);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error al guardar movimiento. Intente nuevamente.'), backgroundColor: AppColors.egreso),
      );
    }
  }

  void _recalcularMontoLts() {
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
    _montoCtrl.dispose();
    _obsCtrl.dispose();
    _litrosCtrl.dispose();
    _precioLitroCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final unidadGestionId = settings.unidadGestionActivaId;
    final isDesktop = MediaQuery.of(context).size.width >= AppSpacing.breakpointTablet;
    final pageTitle = widget.movimientoExistente != null ? 'Editar Movimiento' : 'Nuevo Movimiento';
    
    return ErpLayout(
      currentRoute: '/crear_movimiento',
      title: pageTitle,
      body: Column(
        children: [
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : unidadGestionId == null
                    ? _buildSinUnidadGestion()
                    : _buildFormulario(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSinUnidadGestion() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.warning_amber, size: 64, color: AppColors.advertencia),
            const SizedBox(height: 24),
            const Text(
              'Seleccioná una Unidad de Gestión',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Para cargar movimientos necesitás seleccionar primero una Unidad de Gestión desde Eventos.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildFormulario() {
    final colors = context.appColors;
    return ResponsiveContainer(
      maxWidth: 800,
      child: Container(
        color: colors.bgElevated,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
          // Tipo de movimiento
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tipo de movimiento',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  RadioListTile<String>(
                    title: const Text('💰 Ingreso'),
                    value: 'INGRESO',
                    groupValue: _tipo,
                    activeColor: AppColors.ingreso,
                    onChanged: (v) {
                      setState(() => _tipo = v!);
                      _cargarCategorias();
                    },
                  ),
                  RadioListTile<String>(
                    title: const Text('💸 Egreso'),
                    value: 'EGRESO',
                    groupValue: _tipo,
                    activeColor: AppColors.egreso,
                    onChanged: (v) {
                      setState(() => _tipo = v!);
                      _cargarCategorias();
                    },
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Categoría (I.4: Autocomplete — permite tipear + buscar)
          if (_categorias.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                return Autocomplete<Map<String, dynamic>>(
                  initialValue: _codigoCategoria != null
                      ? TextEditingValue(
                          text: _categorias
                              .where((c) => c['codigo'] == _codigoCategoria)
                              .map((c) => c['nombre'].toString())
                              .firstOrNull ?? '',
                        )
                      : TextEditingValue.empty,
                  displayStringForOption: (cat) => cat['nombre'].toString(),
                  optionsBuilder: (textEditingValue) {
                    if (textEditingValue.text.isEmpty) {
                      return _categorias;
                    }
                    final query = textEditingValue.text.toLowerCase();
                    return _categorias.where((cat) {
                      final nombre = cat['nombre'].toString().toLowerCase();
                      final codigo = cat['codigo'].toString().toLowerCase();
                      return nombre.contains(query) || codigo.contains(query);
                    });
                  },
                  onSelected: (cat) {
                    setState(() => _codigoCategoria = cat['codigo'].toString());
                  },
                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Categoría *',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.category),
                        hintText: 'Escribí para buscar...',
                      ),
                      validator: (_) => _codigoCategoria == null ? 'Requerido' : null,
                      onChanged: (text) {
                        // Si el texto no coincide con ninguna categoría, limpiar selección
                        final match = _categorias.where(
                          (c) => c['nombre'].toString().toLowerCase() == text.toLowerCase(),
                        );
                        if (match.isEmpty) {
                          _codigoCategoria = null;
                        }
                      },
                    );
                  },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: 250,
                            maxWidth: constraints.maxWidth,
                          ),
                          child: ListView.separated(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: options.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final cat = options.elementAt(index);
                              return ListTile(
                                dense: true,
                                leading: Icon(CategoryIconHelper.fromName(cat['icono'] as String?), size: 20),
                                title: Text(cat['nombre'].toString()),
                                subtitle: Text(
                                  cat['codigo'].toString(),
                                  style: AppText.caption,
                                ),
                                onTap: () => onSelected(cat),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.advertenciaDim,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.advertencia),
              ),
              child: const Text(
                '⚠ No hay categorías configuradas para este tipo',
                style: TextStyle(color: AppColors.advertencia),
              ),
            ),
          
          const SizedBox(height: 16),
          
          // Monto (normal ARS) o campos LTS según tipo de acuerdo
          if (widget.unidadAcuerdo == 'LTS') ...[
            // Banner indicador
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                border: Border.all(color: Colors.orange.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.local_gas_station, color: Colors.orange.shade700, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Acuerdo por litros de combustible',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _litrosCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Litros *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.water_drop),
                      suffixText: 'lts',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Requerido';
                      final val = double.tryParse(v.trim().replaceAll(',', '.'));
                      if (val == null || val <= 0) return 'Debe ser mayor a 0';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _precioLitroCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Precio/lt *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.attach_money),
                      prefixText: '\$ ',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Requerido';
                      final val = double.tryParse(v.trim().replaceAll(',', '.'));
                      if (val == null || val <= 0) return 'Debe ser mayor a 0';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            if (_montoArsCalculado != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calculate_outlined, color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Total ARS: \$${_montoArsCalculado!.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                  ],
                ),
              ),
            ],
          ] else
            TextFormField(
              controller: _montoCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.attach_money),
                prefixText: '\$ ',
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Requerido';
                final monto = double.tryParse(v.trim().replaceAll(',', '.'));
                if (monto == null || monto <= 0) return 'Debe ser mayor a 0';
                return null;
              },
            ),
          
          const SizedBox(height: 16),
          
          // Medio de pago
          DropdownButtonFormField<int>(
            value: _medioPagoId,
            decoration: const InputDecoration(
              labelText: 'Medio de pago *',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.payment),
            ),
            items: _metodosPago.map((m) {
              return DropdownMenuItem<int>(
                value: m['id'] as int,
                child: Text(m['descripcion'].toString()),
              );
            }).toList(),
            onChanged: (v) => setState(() => _medioPagoId = v),
            validator: (v) => v == null ? 'Requerido' : null,
          ),
          
          const SizedBox(height: 16),
          
          // Cuenta
          if (_cuentas.isNotEmpty)
            DropdownButtonFormField<int>(
              value: _cuentaId,
              decoration: const InputDecoration(
                labelText: 'Cuenta *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.account_balance_wallet),
                helperText: 'Cuenta donde se registra el movimiento',
              ),
              items: _cuentas.map((cuenta) {
                return DropdownMenuItem<int>(
                  value: cuenta.id,
                  child: Text('${cuenta.nombre} (${cuenta.tipo})'),
                );
              }).toList(),
              onChanged: (v) => setState(() => _cuentaId = v),
              validator: (v) => v == null ? 'Requerido' : null,
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.advertenciaDim,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.advertencia),
              ),
              child: const Text(
                '⚠ No hay cuentas disponibles. Creá una cuenta primero.',
                style: TextStyle(color: AppColors.advertencia),
              ),
            ),
          
          const SizedBox(height: 16),
          
          // Entidad del plantel (opcional)
          DropdownButtonFormField<int?>(
            value: _entidadPlantelId,
            decoration: const InputDecoration(
              labelText: 'Asociar a jugador/staff (opcional)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
              helperText: 'Podés asociar este movimiento a una persona del plantel',
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('Sin asociar'),
              ),
              ..._entidadesPlantel.map((entidad) {
                final id = entidad['id'] as int;
                final nombre = entidad['nombre'] as String;
                final rol = entidad['rol'] as String;
                return DropdownMenuItem<int?>(
                  value: id,
                  child: Text('$nombre ($rol)'),
                );
              }),
            ],
            onChanged: (v) => setState(() => _entidadPlantelId = v),
          ),
          
          const SizedBox(height: 16),
          
          // Evento CDM asociado
          // Si viene preseleccionado desde detalle de evento → mostrar como chip de solo lectura
          // (evita assertion de DropdownButtonFormField cuando el valor no está aún en la lista)
          if (widget.eventoCdmIdInicial != null)
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Evento asociado',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.sports_soccer_outlined),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _eventosCdmMes
                              .where((e) => e['id'] == _eventoCdmId)
                              .map((e) => '${e['titulo'] ?? 'Evento'} (${e['fecha'] ?? ''})')
                              .firstOrNull ??
                          'Evento #$_eventoCdmId',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            )
          else if (_eventosCdmMes.isNotEmpty)
            DropdownButtonFormField<int?>(
              value: _eventosCdmMes.any((e) => e['id'] == _eventoCdmId) ? _eventoCdmId : null,
              decoration: const InputDecoration(
                labelText: 'Evento asociado (opcional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.sports_soccer_outlined),
                helperText: 'Asociá este movimiento a un evento del club',
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Sin evento'),
                ),
                ..._eventosCdmMes.map((ev) {
                  final id = ev['id'] as int;
                  final titulo = ev['titulo'] as String? ?? 'Evento #$id';
                  final fecha = ev['fecha'] as String? ?? '';
                  return DropdownMenuItem<int?>(
                    value: id,
                    child: Text('$titulo${fecha.isNotEmpty ? ' ($fecha)' : ''}'),
                  );
                }),
              ],
              onChanged: (v) => setState(() => _eventoCdmId = v),
            ),
          
          const SizedBox(height: 16),
          
          // Observación
          TextFormField(
            controller: _obsCtrl,
            decoration: const InputDecoration(
              labelText: 'Observación (opcional)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.notes),
            ),
            maxLines: 3,
          ),
          
          const SizedBox(height: 16),
          
          // Archivo adjunto
          OutlinedButton.icon(
            onPressed: _seleccionarArchivo,
            icon: Icon(_attachmentFile != null ? Icons.check_circle : Icons.attach_file),
            label: Text(_attachmentFile != null ? '📎 Archivo adjunto' : 'Adjuntar comprobante'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              side: BorderSide(
                color: _attachmentFile != null ? AppColors.ingreso : colors.textMuted,
              ),
            ),
          ),
          
          if (_attachmentFile != null) ...[
            const SizedBox(height: 12),
            // Mostrar nombre del archivo
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.bgElevated,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(
                    _attachmentFile!.path.toLowerCase().endsWith('.pdf')
                        ? Icons.picture_as_pdf
                        : Icons.image,
                    color: AppColors.ingreso,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      p.basename(_attachmentFile!.path),
                      style: AppText.bodyMd,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Mostrar preview solo si es imagen (no PDF)
            if (!_attachmentFile!.path.toLowerCase().endsWith('.pdf'))
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  _attachmentFile!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
          ],
          
          const SizedBox(height: 24),
          
          // Botón guardar
          FilledButton.icon(
            onPressed: _guardando ? null : _guardar,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.ingreso,
              padding: const EdgeInsets.all(16),
            ),
            icon: _guardando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save),
            label: Text(
              _guardando 
                  ? 'Guardando...' 
                  : widget.movimientoExistente != null 
                      ? 'Actualizar Movimiento' 
                      : 'Guardar Movimiento',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }

  /// Verifica si la cuenta tiene comisión y ofrece registrarla
  Future<void> _verificarComision(int cuentaId, double monto, int disciplinaId, String? eventoId) async {
    try {
      final cuentaService = CuentaService();
      final comision = await cuentaService.calcularComision(cuentaId, monto);
      
      if (comision == null || comision <= 0) return;
      
      if (!mounted) return;
      
      // Mostrar dialog de confirmación con campos editables
      final resultado = await showDialog<Map<String, dynamic>?>(
        context: context,
        builder: (context) => _DialogComision(
          comision: comision,
          cuenta: _cuentas.firstWhere((c) => c.id == cuentaId),
          montoTransferido: monto,
          observacionMovimiento: _obsCtrl.text.trim(),
        ),
      );
      
      if (resultado == null) return; // Usuario canceló
      
      // Obtener valores editados del diálogo
      final montoComision = resultado['monto'] as double? ?? comision;
      final observacionExtra = resultado['observacion'] as String?;
      
      // Registrar comisión como movimiento separado con valores editados
      final svc = EventoMovimientoService();
      final settings = context.read<AppSettings>();
      await svc.crear(
        disciplinaId: disciplinaId,
        cuentaId: cuentaId,
        eventoId: eventoId,
        tipo: 'EGRESO',
        categoria: 'COM_BANC',
        monto: montoComision,
        medioPagoId: _medioPagoId!,
        unidadGestionId: settings.unidadGestionActivaId,
        observacion: observacionExtra ?? 'Comisión bancaria',
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Comisión de ${Format.money(comision)} registrada'),
            backgroundColor: AppColors.advertencia,
          ),
        );
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'crear_movimiento_page.verificar_comision',
        error: e,
        stackTrace: st,
      );
      // Error silencioso - la comisión es opcional
    }
  }
}

/// Dialog para confirmar y editar comisión bancaria
class _DialogComision extends StatefulWidget {
  final double comision;
  final CuentaFondos cuenta;
  final double montoTransferido;
  final String observacionMovimiento;

  const _DialogComision({
    required this.comision,
    required this.cuenta,
    required this.montoTransferido,
    required this.observacionMovimiento,
  });

  @override
  State<_DialogComision> createState() => _DialogComisionState();
}

class _DialogComisionState extends State<_DialogComision> {
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
    final colors = context.appColors;
    
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
                color: colors.infoDim,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.info),
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
                fillColor: colors.bgElevated,
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
                fillColor: colors.bgElevated,
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
