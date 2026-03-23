import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import '../../../data/database/app_database.dart';
import '../../shared/format.dart';
import '../../shared/widgets/responsive_container.dart';
import '../services/adhesion_import_service.dart';

/// Pantalla de importación masiva de acuerdos de adhesiones desde Excel.
///
/// Flujo:
///   1. Instrucciones + descarga de template
///   2. Selector de Subcomisión (unidad de gestión)
///   3. Selector de archivo Excel
///   4. Previsualización con posibilidad de editar fila por fila
///   5. Confirmación → resultado con conteo
class ImportarAdhesionesPage extends StatefulWidget {
  const ImportarAdhesionesPage({super.key});

  @override
  State<ImportarAdhesionesPage> createState() => _ImportarAdhesionesPageState();
}

class _ImportarAdhesionesPageState extends State<ImportarAdhesionesPage> {
  final _svc = AdhesionImportService.instance;

  bool _cargando = false;
  String? _archivoSeleccionado;
  bool _importacionCompletada = false;
  Map<String, dynamic>? _resultadoImport;

  List<Map<String, dynamic>> _filas = [];
  List<String> _erroresGlobales = [];
  Set<String> _nombresEnDB = {};

  List<Map<String, dynamic>> _unidades = [];
  int? _unidadGestionId;

  @override
  void initState() {
    super.initState();
    _cargarUnidades();
  }

  // ─── Carga inicial ───────────────────────────────────────────────────────

  Future<void> _cargarUnidades() async {
    try {
      final db = await AppDatabase.instance();
      final rows = await db.query(
        'unidades_gestion',
        where: 'activo = 1',
        orderBy: 'nombre',
      );
      final defaultUg = rows.firstWhere(
        (u) => (u['nombre'] as String).toLowerCase().contains('mayor'),
        orElse: () => rows.isNotEmpty ? rows.first : {},
      );
      if (mounted) {
        setState(() {
          _unidades = rows;
          _unidadGestionId =
              defaultUg.isNotEmpty ? defaultUg['id'] as int? : rows.isNotEmpty ? rows.first['id'] as int : null;
        });
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'importar_adhesiones.cargar_unidades',
        error: e.toString(),
        stackTrace: stack,
      );
    }
  }

  // ─── Acciones ────────────────────────────────────────────────────────────

  Future<void> _descargarTemplate() async {
    try {
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final suggestedName = 'adhesiones_template_$timestamp.xlsx';

      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar template de adhesiones',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (outputPath == null) return;

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Generando template...'),
              ],
            ),
          ),
        );
      }

      final tempPath = await _svc.generarTemplate();
      final tempFile = File(tempPath);
      await tempFile.copy(outputPath);
      await tempFile.delete();

      if (mounted) Navigator.pop(context);

      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[700]),
                const SizedBox(width: 8),
                const Text('Template descargado'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El archivo se guardó correctamente en:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(outputPath, style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Completá la hoja "Adhesiones" y luego seleccioná el archivo para importar.',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  final directory = File(outputPath).parent.path;
                  await Process.run('explorer', [directory]);
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Abrir carpeta'),
              ),
            ],
          ),
        );
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'importar_adhesiones.descargar_template',
        error: e.toString(),
        stackTrace: stack,
      );
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al generar template: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _seleccionarArchivo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );
      if (result == null) return;

      final filePath = result.files.single.path;
      if (filePath == null) throw Exception('No se pudo leer el archivo.');

      setState(() {
        _cargando = true;
        _archivoSeleccionado = filePath;
      });

      final datos = await _svc.leerArchivoExcel(filePath);

      setState(() {
        _filas = List<Map<String, dynamic>>.from(datos['filas'] as List);
        _erroresGlobales = List<String>.from(datos['erroresGlobales'] as List);
        _nombresEnDB = (datos['nombresEnDB'] as Set).cast<String>();
        _cargando = false;
        _importacionCompletada = false;
        _resultadoImport = null;
      });

      if (_filas.isEmpty && _erroresGlobales.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('El archivo no contiene datos válidos.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'importar_adhesiones.seleccionar_archivo',
        error: e.toString(),
        stackTrace: stack,
      );
      setState(() => _cargando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al leer el archivo: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _confirmarImportacion() async {
    if (_unidadGestionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Seleccioná una subcomisión antes de importar.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final filasValidas = _filas.where((f) => f['valido'] as bool).toList();
    if (filasValidas.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay filas válidas para importar.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Nombre de la unidad para mostrar en el diálogo
    final unidadNombre = (_unidades.firstWhere(
      (u) => u['id'] == _unidadGestionId,
      orElse: () => {'nombre': 'N/A'},
    )['nombre'] as String);

    final advertenciasCount = _filas.where((f) => f['esDuplicado'] as bool).length;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.upload_file, color: Colors.blue[700]),
            const SizedBox(width: 8),
            const Text('Confirmar importación'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dialogInfoRow(Icons.corporate_fare, 'Subcomisión', unidadNombre),
            const SizedBox(height: 8),
            _dialogInfoRow(Icons.check_circle, 'Acuerdos a crear',
                '${filasValidas.length}', Colors.green[700]),
            if (advertenciasCount > 0) ...[
              const SizedBox(height: 8),
              _dialogInfoRow(Icons.warning_amber, 'Con nombre duplicado',
                  '$advertenciasCount (se crearán igual)', Colors.orange[800]),
            ],
            if (_filas.any((f) => !(f['valido'] as bool))) ...[
              const SizedBox(height: 8),
              _dialogInfoRow(Icons.cancel, 'Con errores (no se importarán)',
                  '${_filas.where((f) => !(f['valido'] as bool)).length}', Colors.red[700]),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text('Importar'),
          ),
        ],
      ),
    );

    if (confirmar != true || !mounted) return;

    setState(() => _cargando = true);

    try {
      final resultado = await _svc.importarAdhesiones(_filas, _unidadGestionId!);
      setState(() {
        _importacionCompletada = true;
        _resultadoImport = resultado;
        _cargando = false;
      });
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'importar_adhesiones.confirmar_importacion',
        error: e.toString(),
        stackTrace: stack,
      );
      setState(() => _cargando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error durante la importación: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _editarFila(int index) async {
    final fila = Map<String, dynamic>.from(_filas[index]);

    // Controllers pre-poblados con los valores actuales
    final nombreCtrl = TextEditingController(text: fila['nombre'] as String? ?? '');
    final montoCtrl = TextEditingController(text: fila['montoRaw'] as String? ?? '');
    final fechaInicioCtrl = TextEditingController(text: fila['fechaInicioRaw'] as String? ?? '');
    final fechaFinCtrl = TextEditingController(text: fila['fechaFinRaw'] as String? ?? '');
    final obsCtrl = TextEditingController(text: fila['observaciones'] as String? ?? '');
    String selectedSubcat =
        AdhesionImportService.subcategoriasValidas.contains(fila['subcategoria'])
            ? fila['subcategoria'] as String
            : AdhesionImportService.subcategoriasValidas.first;
    String selectedUnidad = (fila['unidad'] as String? ?? 'ARS') == 'LTS' ? 'Litros' : 'Dinero';

    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.edit),
              const SizedBox(width: 8),
              Text('Editar fila ${fila['filaExcel']}'),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nombreCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nombre *',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedSubcat,
                      decoration: const InputDecoration(
                        labelText: 'Subcategoría *',
                        border: OutlineInputBorder(),
                      ),
                      items: AdhesionImportService.subcategoriasValidas
                          .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedSubcat = v!),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: montoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Monto *',
                        border: OutlineInputBorder(),
                        hintText: 'Ej: 5000',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Requerido';
                        final n = double.tryParse(v.trim().replaceAll(',', '.'));
                        if (n == null || n <= 0) return 'Debe ser mayor a 0';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedUnidad,
                      decoration: const InputDecoration(
                        labelText: 'Unidad',
                        border: OutlineInputBorder(),
                        helperText: 'Solo aplica a Combustible',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Dinero', child: Text('Dinero (\$ARS)')),
                        DropdownMenuItem(value: 'Litros', child: Text('Litros (LTS)')),
                      ],
                      onChanged: (v) => setDialogState(() => selectedUnidad = v!),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fechaInicioCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Fecha Inicio *',
                        border: OutlineInputBorder(),
                        hintText: 'dd/mm/yyyy',
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Requerido';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fechaFinCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Fecha Fin',
                        border: OutlineInputBorder(),
                        hintText: 'dd/mm/yyyy (opcional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: obsCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Observaciones',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() == true) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    // Actualizar los datos crudos de la fila y revalidar
    final filaActualizada = Map<String, dynamic>.from(fila);
    filaActualizada['nombre'] = nombreCtrl.text.trim();
    filaActualizada['subcategoria'] = selectedSubcat;
    filaActualizada['montoRaw'] = montoCtrl.text.trim();
    filaActualizada['fechaInicioRaw'] = fechaInicioCtrl.text.trim();
    filaActualizada['fechaFinRaw'] = fechaFinCtrl.text.trim();
    filaActualizada['observaciones'] = obsCtrl.text.trim();
    filaActualizada['unidad'] = selectedUnidad == 'Litros' ? 'LTS' : 'ARS';

    final revalidada = _svc.revalidarFila(filaActualizada, _nombresEnDB);

    setState(() {
      final newFilas = List<Map<String, dynamic>>.from(_filas);
      newFilas[index] = revalidada;
      _filas = newFilas;
    });
  }

  void _revalidarTodo() {
    final revalidadas = _filas
        .map((f) => _svc.revalidarFila(Map<String, dynamic>.from(f), _nombresEnDB))
        .toList();
    setState(() => _filas = revalidadas);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Revalidación completada.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _limpiarSeleccion() {
    setState(() {
      _archivoSeleccionado = null;
      _filas = [];
      _erroresGlobales = [];
      _nombresEnDB = {};
      _importacionCompletada = false;
      _resultadoImport = null;
    });
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Importar Adhesiones'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Descargar template Excel',
            onPressed: _descargarTemplate,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ResponsiveContainer(
              maxWidth: 900,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildInstrucciones(),
                    const SizedBox(height: 20),

                    if (!_importacionCompletada) ...[
                      _buildSelectorUnidad(),
                      const SizedBox(height: 16),
                      _buildSelectorArchivo(),
                      const SizedBox(height: 16),

                      if (_erroresGlobales.isNotEmpty) ...[
                        _buildErroresGlobales(),
                        const SizedBox(height: 16),
                      ],

                      if (_filas.isNotEmpty) ...[
                        _buildResumenEstado(),
                        const SizedBox(height: 12),
                        _buildPreview(),
                        const SizedBox(height: 16),
                        _buildBotonesAccion(),
                      ],
                    ],

                    if (_importacionCompletada && _resultadoImport != null) ...[
                      const SizedBox(height: 16),
                      _buildResultado(),
                    ],

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }

  // ─── Widgets de sección ──────────────────────────────────────────────────

  Widget _buildInstrucciones() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  '¿Cómo importar acuerdos de adhesión?',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 20),
            _instruccionItem('1', 'Descargá el template Excel usando el botón ↓ de arriba a la derecha.'),
            _instruccionItem('2', 'Completá la hoja "Adhesiones" con los datos de cada adherente.'),
            _instruccionItem('3', 'Seleccioná la subcomisión a la que pertenecen estas adhesiones.'),
            _instruccionItem('4', 'Subí el archivo completo con el botón "Seleccionar archivo Excel".'),
            _instruccionItem('5', 'Revisá la previsualización. Podés editar cualquier fila antes de confirmar.'),
            _instruccionItem('6', 'Hacé clic en "Confirmar Importación" para crear los acuerdos.'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                border: Border.all(color: Colors.blue[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, color: Colors.blue[800], size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'El campo "Unidad" aplica solo a Combustible: '
                      '"Dinero" = monto en pesos ARS, "Litros" = monto en litros LTS.\n'
                      'Si lo dejás vacío se usa "Dinero" por defecto.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                border: Border.all(color: Colors.amber[400]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber, color: Colors.amber[800], size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Los acuerdos se crearán como: Tipo INGRESO · Categoría ADHESIONES · Frecuencia MENSUAL. '
                      'La subcomisión se elige una sola vez y aplica a todas las filas del archivo.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _instruccionItem(String numero, String texto) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.blue[700],
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                numero,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(texto))),
        ],
      ),
    );
  }

  Widget _buildSelectorUnidad() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Subcomisión',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              'Todos los acuerdos del archivo pertenecerán a esta subcomisión.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _unidadGestionId,
              decoration: const InputDecoration(
                labelText: 'Subcomisión *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.corporate_fare),
              ),
              items: _unidades
                  .map((u) => DropdownMenuItem<int>(
                        value: u['id'] as int,
                        child: Text(u['nombre'] as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _unidadGestionId = v),
              validator: (v) => v == null ? 'Seleccioná una subcomisión' : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectorArchivo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Seleccionar Archivo Excel',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (_archivoSeleccionado != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  border: Border.all(color: Colors.green[400]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file, color: Colors.green[700]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Archivo seleccionado:', style: TextStyle(fontSize: 12)),
                          Text(
                            _archivoSeleccionado!.split(Platform.pathSeparator).last,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _limpiarSeleccion,
                      tooltip: 'Quitar archivo',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            ElevatedButton.icon(
              onPressed: _seleccionarArchivo,
              icon: const Icon(Icons.upload_file),
              label: Text(_archivoSeleccionado == null ? 'Seleccionar archivo Excel' : 'Cambiar archivo'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErroresGlobales() {
    return Card(
      color: Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red[700]),
                const SizedBox(width: 8),
                Text(
                  'Errores en el archivo (${_erroresGlobales.length})',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red[900]),
                ),
              ],
            ),
            const Divider(height: 16),
            ..._erroresGlobales.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle, size: 6, color: Colors.red[700]),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumenEstado() {
    final total = _filas.length;
    final validas = _filas.where((f) => f['valido'] as bool).length;
    final advertencias = _filas.where((f) => f['esDuplicado'] as bool).length;
    final errores = _filas.where((f) => !(f['valido'] as bool)).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Previsualización ($total filas)',
                  style:
                      Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _revalidarTodo,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Re-validar todo'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                Chip(
                  avatar: Icon(Icons.check_circle, color: Colors.green[700], size: 16),
                  label: Text('$validas OK'),
                  backgroundColor: Colors.green[50],
                  visualDensity: VisualDensity.compact,
                ),
                if (advertencias > 0)
                  Chip(
                    avatar: Icon(Icons.warning_amber, color: Colors.orange[800], size: 16),
                    label: Text('$advertencias nombre duplicado'),
                    backgroundColor: Colors.orange[50],
                    visualDensity: VisualDensity.compact,
                  ),
                if (errores > 0)
                  Chip(
                    avatar: Icon(Icons.cancel, color: Colors.red[700], size: 16),
                    label: Text('$errores con error'),
                    backgroundColor: Colors.red[50],
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _filas.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, i) {
            try {
              return _buildFilaCard(i);
            } catch (e) {
              AppDatabase.logLocalError(
                scope: 'importar_adhesiones.render_fila',
                error: e.toString(),
                stackTrace: StackTrace.current,
                payload: {'index': i},
              );
              return ListTile(
                leading: const Icon(Icons.warning, color: Colors.orange),
                title: Text('Error al mostrar fila ${i + 1}'),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildFilaCard(int index) {
    final fila = _filas[index];
    final valido = fila['valido'] as bool;
    final esDuplicado = fila['esDuplicado'] as bool;
    final errores = (fila['errores'] as List).cast<String>();

    Color? bgColor;
    if (!valido) {
      bgColor = Colors.red[50];
    } else if (esDuplicado) {
      bgColor = Colors.orange[50];
    } else {
      bgColor = Colors.green[50];
    }

    final monto = (fila['monto'] as num?)?.toDouble() ?? 0.0;
    final unidad = fila['unidad'] as String? ?? 'ARS';
    final montoStr = unidad == 'LTS'
        ? '${Format.numero(monto)} Litros'
        : Format.money(monto);
    return Container(
      color: bgColor,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!valido)
              Tooltip(
                message: errores.join('\n'),
                child: Icon(Icons.cancel, color: Colors.red[700]),
              )
            else if (esDuplicado)
              Tooltip(
                message: 'El nombre ya existe en la base de datos.\nSe creará de todas formas.',
                child: Icon(Icons.warning_amber, color: Colors.orange[800]),
              )
            else
              Icon(Icons.check_circle, color: Colors.green[700]),
          ],
        ),
        title: Row(
          children: [
            Text(
              '#${fila['filaNum']}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fila['nombre'] as String? ?? '-',
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip(fila['subcategoria'] as String? ?? '-', Colors.blue[100]!),
                _chip(montoStr, Colors.teal[100]!),
                _chip(
                  '${fila['fechaInicioRaw'] ?? '-'}${(fila['fechaFinRaw'] as String?)?.isNotEmpty == true ? ' → ${fila['fechaFinRaw']}' : ''}',
                  Colors.purple[50]!,
                ),
                if ((fila['observaciones'] as String?)?.isNotEmpty == true)
                  _chip('📝 ${fila['observaciones']}', Colors.grey[200]!),
              ],
            ),
            if (!valido && errores.isNotEmpty) ...[
              const SizedBox(height: 4),
              ...errores.map(
                (e) => Text(
                  '• $e',
                  style: TextStyle(fontSize: 12, color: Colors.red[800]),
                ),
              ),
            ],
            if (esDuplicado && valido)
              Text(
                '⚠ Nombre ya existente en la base de datos (se creará igual)',
                style: TextStyle(fontSize: 12, color: Colors.orange[800]),
              ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit, size: 20),
          tooltip: 'Editar',
          onPressed: () => _editarFila(index),
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _chip(String label, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildBotonesAccion() {
    final validasCount = _filas.where((f) => f['valido'] as bool).length;

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _limpiarSeleccion,
            icon: const Icon(Icons.cancel),
            label: const Text('Cancelar'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(16)),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            onPressed: validasCount > 0 ? _confirmarImportacion : null,
            icon: const Icon(Icons.upload),
            label: Text('Confirmar importación ($validasCount acuerdos)'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
          ),
        ),
      ],
    );
  }

  Widget _buildResultado() {
    final creados = (_resultadoImport!['creados'] as int?) ?? 0;
    final conAdvertencias = (_resultadoImport!['conAdvertencias'] as int?) ?? 0;
    final erroresPorFila =
        ((_resultadoImport!['erroresPorFila']) as List).cast<String>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              creados > 0 ? Icons.check_circle : Icons.info_outline,
              size: 64,
              color: creados > 0 ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 16),
            Text(
              creados > 0
                  ? '¡Importación completada!'
                  : 'Importación finalizada sin acuerdos creados.',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _resultadoItem(Icons.add_circle, 'Acuerdos creados', creados.toString(), Colors.green),

            if (conAdvertencias > 0) ...[
              const SizedBox(height: 12),
              _resultadoItem(
                Icons.warning_amber,
                'Creados con nombre duplicado',
                conAdvertencias.toString(),
                Colors.orange,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4),
                child: Text(
                  'Estos acuerdos tienen el mismo nombre que uno ya existente. '
                  'Revisalos en la pantalla de Adhesiones.',
                  style: TextStyle(fontSize: 13, color: Colors.orange[800]),
                ),
              ),
            ],

            if (erroresPorFila.isNotEmpty) ...[
              const SizedBox(height: 12),
              _resultadoItem(
                  Icons.error, 'Filas con error (no importadas)', erroresPorFila.length.toString(), Colors.red),
              const SizedBox(height: 8),
              ...erroresPorFila.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(left: 48, top: 4),
                  child: Text('• $e', style: const TextStyle(fontSize: 13)),
                ),
              ),
            ],

            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _limpiarSeleccion,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Importar otro archivo'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, creados > 0),
                    icon: const Icon(Icons.done),
                    label: const Text('Finalizar'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.all(14)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultadoItem(IconData icon, String label, String valor, Color color) {
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
        Chip(
          label: Text(valor, style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: color.withValues(alpha: 0.15),
        ),
      ],
    );
  }

  Widget _dialogInfoRow(IconData icon, String label, String valor, [Color? valueColor]) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: valueColor ?? Colors.grey[700]),
        const SizedBox(width: 8),
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500)),
        Expanded(
          child: Text(
            valor,
            style: TextStyle(color: valueColor),
          ),
        ),
      ],
    );
  }
}
