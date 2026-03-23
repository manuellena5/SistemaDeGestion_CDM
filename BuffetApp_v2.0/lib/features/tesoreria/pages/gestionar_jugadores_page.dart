import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../shared/widgets/responsive_container.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/skeleton_loader.dart';
import 'package:intl/intl.dart';
import '../../../data/dao/db.dart';
import '../../../features/shared/services/plantel_service.dart';
import '../../../features/shared/services/plantel_import_export_service.dart';
import '../../../layout/erp_layout.dart';
import 'crear_jugador_page.dart';
import 'detalle_jugador_page.dart';
import 'editar_jugador_page.dart';
import 'importar_jugadores_page.dart';

/// FASE 17.6: Pantalla de gestión (ABM) de jugadores y cuerpo técnico.
/// Permite listar, filtrar, crear, editar y dar de baja entidades del plantel.
class GestionarJugadoresPage extends StatefulWidget {
  const GestionarJugadoresPage({Key? key}) : super(key: key);

  @override
  State<GestionarJugadoresPage> createState() => _GestionarJugadoresPageState();
}

class _GestionarJugadoresPageState extends State<GestionarJugadoresPage> {
  final _plantelSvc = PlantelService.instance;
  final _importExportSvc = PlantelImportExportService.instance;

  List<Map<String, dynamic>> _entidades = [];
  bool _cargando = true;
  String _filtroRol = 'TODOS';
  String _filtroEstado = 'ACTIVOS';
  String _filtroTipoContratacion = 'TODOS'; // TODOS, LOCAL, REFUERZO, OTRO
  Set<int> _jugadoresSeleccionados = {}; // IDs de jugadores seleccionados

  @override
  void initState() {
    super.initState();
    _cargarEntidades();
  }

  List<Map<String, dynamic>> _entidadesOriginales = [];

  Future<void> _cargarEntidades() async {
    setState(() => _cargando = true);
    try {
      final soloActivos = _filtroEstado == 'ACTIVOS';
      final entidades = await _plantelSvc.listarEntidades(
        rol: _filtroRol == 'TODOS' ? null : _filtroRol,
        soloActivos: soloActivos,
      );
      setState(() {
        _entidadesOriginales = entidades;
        _aplicarFiltros();
        _jugadoresSeleccionados.clear(); // Limpiar selección al recargar
      });
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'gestionar_jugadores.cargar_entidades',
        error: e.toString(),
        stackTrace: stack,
        payload: {'filtro_rol': _filtroRol, 'filtro_estado': _filtroEstado},
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al cargar entidades. Por favor, intente nuevamente.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _cargando = false);
    }
  }

  void _aplicarFiltros() {
    if (_filtroTipoContratacion == 'TODOS') {
      _entidades = _entidadesOriginales;
    } else {
      _entidades = _entidadesOriginales.where((e) {
        final tipo = (e['tipo_contratacion'] as String?) ?? '';
        return tipo.toUpperCase() == _filtroTipoContratacion;
      }).toList();
    }
  }

  void _irACrear() async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CrearJugadorPage()),
    );
    if (resultado == true) {
      _cargarEntidades();
    }
  }

  Future<void> _cambiarEstado(int id, bool activar) async {
    try {
      if (activar) {
        await _plantelSvc.reactivarEntidad(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Entidad reactivada'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        await _plantelSvc.darDeBajaEntidad(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Entidad dada de baja'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
      _cargarEntidades();
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'gestionar_jugadores.cambiar_estado',
        error: e.toString(),
        stackTrace: stack,
        payload: {'entidad_id': id, 'activar': activar},
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('compromisos activos')
                ? 'No se puede dar de baja: tiene compromisos activos'
                : 'Error al cambiar estado. Por favor, intente nuevamente.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ErpLayout(
      title: 'Gestionar Jugadores',
      currentRoute: '/gestionar_jugadores',
      actions: [
        // Importar
        IconButton(
          icon: const Icon(Icons.upload_file),
          tooltip: 'Importar desde Excel',
          onPressed: _irAImportar,
        ),
        // Exportar
        PopupMenuButton<String>(
          icon: const Icon(Icons.download),
          tooltip: 'Exportar a Excel',
          onSelected: _exportar,
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'TODOS',
              child: Text('Exportar todos'),
            ),
            const PopupMenuItem(
              value: 'JUGADOR',
              child: Text('Exportar jugadores'),
            ),
            const PopupMenuItem(
              value: 'DT',
              child: Text('Exportar DT'),
            ),
            const PopupMenuItem(
              value: 'AYUDANTE',
              child: Text('Exportar Ayudantes'),
            ),
          ],
        ),
      ],
      body: ResponsiveContainer(
        maxWidth: 1400,
        child: RefreshIndicator(
          onRefresh: _cargarEntidades,
        child: Column(
          children: [
            // Filtros
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.grey.shade100,
              child: Column(
                children: [
                  // Filtro por rol
                  Row(
                    children: [
                      const Text('Rol:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'TODOS', label: Text('Todos')),
                            ButtonSegment(value: 'JUGADOR', label: Text('Jugadores')),
                            ButtonSegment(value: 'DT', label: Text('DT')),
                            ButtonSegment(value: 'AYUDANTE', label: Text('Ayudante')),
                            ButtonSegment(value: 'PF', label: Text('PF')),
                          ],
                          selected: {_filtroRol},
                          onSelectionChanged: (Set<String> selected) {
                            setState(() => _filtroRol = selected.first);
                            _cargarEntidades();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Filtro por estado
                  Row(
                    children: [
                      const Text('Estado:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'ACTIVOS', label: Text('Activos')),
                            ButtonSegment(value: 'BAJA', label: Text('De baja')),
                            ButtonSegment(value: 'TODOS', label: Text('Todos')),
                          ],
                          selected: {_filtroEstado},
                          onSelectionChanged: (Set<String> selected) {
                            setState(() => _filtroEstado = selected.first);
                            _cargarEntidades();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Filtro por tipo de contratación
                  Row(
                    children: [
                      const Text('Tipo Contratación:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'TODOS', label: Text('Todos')),
                            ButtonSegment(value: 'LOCAL', label: Text('Local')),
                            ButtonSegment(value: 'REFUERZO', label: Text('Refuerzo')),
                            ButtonSegment(value: 'OTRO', label: Text('Otro')),
                          ],
                          selected: {_filtroTipoContratacion},
                          onSelectionChanged: (Set<String> selected) {
                            setState(() => _filtroTipoContratacion = selected.first);
                            _aplicarFiltros();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Lista
            Expanded(
              child: _cargando
                  ? SkeletonLoader.cards(count: 4)
                  : _entidades.isEmpty
                      ? EmptyState(
                          icon: Icons.people_outline,
                          title: 'No hay entidades registradas',
                          action: ElevatedButton.icon(
                            onPressed: _irACrear,
                            icon: const Icon(Icons.add),
                            label: const Text('Agregar primera entidad'),
                          ),
                        )
                      : _buildTabla(),
            ),
          ],
          ),
        ),
      ),
      floatingActionButton: _jugadoresSeleccionados.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _irACrear,
              icon: const Icon(Icons.person_add),
              label: const Text('Nuevo'),
            )
          : FloatingActionButton.extended(
              onPressed: _confirmarBajaMasiva,
              backgroundColor: Colors.orange,
              icon: const Icon(Icons.person_remove),
              label: Text('Dar de baja (${_jugadoresSeleccionados.length})'),
            ),
    );
  }

  Widget _buildTabla() {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: MaterialStateProperty.all(Colors.grey.shade200),
          showCheckboxColumn: true,
          columns: const [
            DataColumn(label: Text('Detalle', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Nombre', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Rol', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Edad', style: TextStyle(fontWeight: FontWeight.bold)), numeric: true),
            DataColumn(label: Text('Posición', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Tipo Contratación', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Estado', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Acciones', style: TextStyle(fontWeight: FontWeight.bold))),
          ],
          rows: _entidades.map((entidad) {
            final id = entidad['id'] as int;
            final nombre = entidad['nombre'] as String;
            final rol = entidad['rol'] as String;
            final activo = (entidad['estado_activo'] as int) == 1;
            final posicion = entidad['posicion'] as String? ?? '-';
            final tipoContratacion = entidad['tipo_contratacion'] as String? ?? '-';
            final fechaNacStr = entidad['fecha_nacimiento'] as String?;
            String edadStr = '-';
            if (fechaNacStr != null && fechaNacStr.isNotEmpty) {
              try {
                final nacimiento = DateTime.parse(fechaNacStr);
                final hoy = DateTime.now();
                int edad = hoy.year - nacimiento.year;
                if (hoy.month < nacimiento.month ||
                    (hoy.month == nacimiento.month && hoy.day < nacimiento.day)) {
                  edad--;
                }
                edadStr = '$edad';
              } catch (_) {}
            }

            return DataRow(
              selected: _jugadoresSeleccionados.contains(id),
              onSelectChanged: activo ? (selected) {
                setState(() {
                  if (selected == true) {
                    _jugadoresSeleccionados.add(id);
                  } else {
                    _jugadoresSeleccionados.remove(id);
                  }
                });
              } : null, // No permitir seleccionar jugadores dados de baja
              color: MaterialStateProperty.all(
                activo ? null : Colors.grey.shade100,
              ),
              cells: [
                DataCell(
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: 'Ver detalle',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DetalleJugadorPage(entidadId: id),
                        ),
                      ).then((_) => _cargarEntidades());
                    },
                  ),
                ),
                DataCell(Text(
                  nombre,
                  style: TextStyle(
                    decoration: activo ? null : TextDecoration.lineThrough,
                  ),
                )),
                DataCell(Text(_nombreRol(rol))),
                DataCell(Text(edadStr)),
                DataCell(Text(posicion)),
                DataCell(Text(tipoContratacion)),
                DataCell(
                  Chip(
                    label: Text(
                      activo ? 'ACTIVO' : 'BAJA',
                      style: const TextStyle(fontSize: 10),
                    ),
                    backgroundColor: activo ? Colors.green.shade100 : Colors.grey.shade300,
                    side: BorderSide.none,
                  ),
                ),
                DataCell(
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _mostrarMenuAcciones(id, nombre, activo),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  void _mostrarMenuAcciones(int id, String nombre, bool activo) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Editar'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditarJugadorPage(entidadId: id),
                  ),
                ).then((_) => _cargarEntidades());
              },
            ),
            ListTile(
              leading: Icon(activo ? Icons.block : Icons.check_circle),
              title: Text(activo ? 'Dar de baja' : 'Reactivar'),
              onTap: () {
                Navigator.pop(context);
                _confirmarCambioEstado(id, nombre, activo);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmarCambioEstado(int id, String nombre, bool activo) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(activo ? 'Dar de baja' : 'Reactivar'),
        content: Text(
          activo
              ? '¿Confirmar dar de baja a "$nombre"?\n\nSolo se puede dar de baja si no tiene compromisos activos.'
              : '¿Confirmar reactivación de "$nombre"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _cambiarEstado(id, !activo);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: activo ? Colors.orange : Colors.green,
            ),
            child: Text(activo ? 'Dar de baja' : 'Reactivar'),
          ),
        ],
      ),
    );
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
        return Colors.blue;
      case 'DT':
        return Colors.purple;
      case 'AYUDANTE':
        return Colors.teal;
      case 'PF':
        return Colors.orange;
      case 'OTRO':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  // ========== BAJA MASIVA ==========

  Future<void> _confirmarBajaMasiva() async {
    if (_jugadoresSeleccionados.isEmpty) return;

    // Obtener nombres de los jugadores seleccionados
    final jugadoresADarDeBaja = _entidades
        .where((e) => _jugadoresSeleccionados.contains(e['id'] as int))
        .toList();

    final resultado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar baja masiva'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Se van a dar de baja los siguientes ${jugadoresADarDeBaja.length} jugadores:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: jugadoresADarDeBaja.map((j) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(Icons.person, size: 16, color: Colors.grey[600]),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${j['nombre']} (${_nombreRol(j['rol'] as String)})',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                border: Border.all(color: Colors.orange),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange[800]),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Solo se darán de baja los que no tengan compromisos activos.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Confirmar baja'),
          ),
        ],
      ),
    );

    if (resultado == true) {
      await _ejecutarBajaMasiva(jugadoresADarDeBaja);
    }
  }

  Future<void> _ejecutarBajaMasiva(List<Map<String, dynamic>> jugadores) async {
    int exitosos = 0;
    int fallidos = 0;
    final errores = <String>[];

    // Mostrar progreso
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Dando de baja ${jugadores.length} jugadores...'),
            ],
          ),
        ),
      );
    }

    for (final jugador in jugadores) {
      try {
        await _plantelSvc.darDeBajaEntidad(jugador['id'] as int);
        exitosos++;
      } catch (e) {
        fallidos++;
        errores.add('${jugador['nombre']}: ${e.toString()}');
        await AppDatabase.logLocalError(
          scope: 'gestionar_jugadores.baja_masiva',
          error: e.toString(),
          payload: {'jugador_id': jugador['id'], 'nombre': jugador['nombre']},
        );
      }
    }

    // Cerrar diálogo de progreso
    if (mounted) Navigator.pop(context);

    // Limpiar selección y recargar
    setState(() => _jugadoresSeleccionados.clear());
    await _cargarEntidades();

    // Mostrar resultado
    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(
                exitosos > 0 ? Icons.check_circle : Icons.error,
                color: exitosos > 0 ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              const Text('Resultado de baja masiva'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (exitosos > 0) ...[
                Row(
                  children: [
                    Icon(Icons.check, color: Colors.green[700]),
                    const SizedBox(width: 8),
                    Text(
                      'Exitosos: $exitosos',
                      style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (fallidos > 0) ...[
                Row(
                  children: [
                    Icon(Icons.error, color: Colors.red[700]),
                    const SizedBox(width: 8),
                    Text(
                      'Fallidos: $fallidos',
                      style: TextStyle(color: Colors.red[700], fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Errores:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: errores.map((e) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '• $e',
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    }
  }

  // ========== IMPORT / EXPORT ==========

  Future<void> _irAImportar() async {
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ImportarJugadoresPage()),
    );
    if (resultado == true) {
      _cargarEntidades();
    }
  }

  Future<void> _exportar(String? rol) async {
    try {
      final soloActivos = _filtroEstado == 'ACTIVOS';
      final rolExportar = rol == 'TODOS' ? null : rol;
      
      // Calcular cantidad a exportar
      final cantExportados = _entidades.where((e) {
        final matchRol = rolExportar == null || e['rol'] == rolExportar;
        final matchEstado = !soloActivos || (e['estado_activo'] as int?) == 1;
        return matchRol && matchEstado;
      }).length;

      if (cantExportados == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No hay jugadores para exportar con los filtros actuales'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Pedir al usuario dónde guardar el archivo
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final estadoStr = soloActivos ? 'activos' : 'todos';
      final rolStr = rolExportar ?? 'todos';
      final suggestedName = 'plantel_${rolStr}_${estadoStr}_$timestamp.xlsx';
      
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Exportar plantel a Excel',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (outputPath == null) {
        // Usuario canceló
        return;
      }

      // Mostrar diálogo de progreso
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Exportando $cantExportados jugadores...'),
              ],
            ),
          ),
        );
      }

      // Generar el archivo en temp
      final tempPath = await _importExportSvc.exportarJugadores(
        rol: rolExportar,
        soloActivos: soloActivos,
      );

      // Copiar a la ubicación elegida
      final tempFile = File(tempPath);
      await tempFile.copy(outputPath);
      
      // Eliminar temporal
      await tempFile.delete();

      // Cerrar diálogo de progreso
      if (mounted) Navigator.pop(context);

      // Mostrar resultado exitoso
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[700]),
                const SizedBox(width: 8),
                const Text('Exportación exitosa'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se exportaron $cantExportados jugadores correctamente.',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Archivo guardado en:',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    outputPath,
                    style: const TextStyle(fontSize: 11),
                  ),
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
                  // Abrir explorador en la carpeta
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
        scope: 'gestionar_jugadores.exportar',
        error: e.toString(),
        stackTrace: stack,
        payload: {'rol': rol, 'filtro_estado': _filtroEstado},
      );

      // Cerrar diálogo de progreso si está abierto
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.error, color: Colors.red[700]),
                const SizedBox(width: 8),
                const Text('Error'),
              ],
            ),
            content: Text('Error al exportar:\n\n${e.toString()}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        );
      }
    }
  }
}

