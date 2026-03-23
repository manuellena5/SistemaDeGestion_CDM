import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/widgets/responsive_container.dart';
import '../../shared/widgets/breadcrumb.dart';
import '../../shared/widgets/skeleton_loader.dart';

import '../../../features/shared/services/acuerdos_service.dart';
import '../../../features/shared/services/compromisos_service.dart';
import '../../../features/shared/format.dart';
import '../../../data/dao/db.dart';
import '../services/categoria_movimiento_service.dart';
import '../services/acuerdos_grupales_service.dart';
import 'editar_acuerdo_page.dart';
import 'detalle_compromiso_page.dart';

/// FASE 18.7: Página de detalle de un acuerdo
/// 
/// Muestra:
/// - Información completa del acuerdo
/// - Estadísticas de progreso
/// - Lista de compromisos generados
/// - Acciones: editar, finalizar, eliminar
class DetalleAcuerdoPage extends StatefulWidget {
  final int acuerdoId;

  const DetalleAcuerdoPage({super.key, required this.acuerdoId});

  @override
  State<DetalleAcuerdoPage> createState() => _DetalleAcuerdoPageState();
}

class _DetalleAcuerdoPageState extends State<DetalleAcuerdoPage> {
  final _compromisosService = CompromisosService.instance;
  final _grupalSvc = AcuerdosGrupalesService.instance;
  
  Map<String, dynamic>? _acuerdo;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _compromisos = [];
  bool _isLoading = true;
  String? _categoriaNombre;
  
  // FASE 19: Datos de origen grupal
  Map<String, dynamic>? _historico;
  List<Map<String, dynamic>> _acuerdosHermanos = [];

  /// Formatea un monto considerando si el acuerdo es en LTS (litros) o ARS.
  String _fmtMonto(double v) {
    if ((_acuerdo?['unidad'] as String?) == 'LTS') {
      return '${v.toStringAsFixed(2)} lts';
    }
    return Format.money(v);
  }

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _isLoading = true);
    
    try {
      final acuerdoRaw = await AcuerdosService.obtenerAcuerdo(widget.acuerdoId);
      
      if (acuerdoRaw == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Acuerdo no encontrado')),
          );
          Navigator.pop(context);
        }
        return;
      }
      
      // Convertir a Map mutable para poder enriquecerlo
      final acuerdo = Map<String, dynamic>.from(acuerdoRaw);
      
      final stats = await AcuerdosService.obtenerEstadisticasAcuerdo(widget.acuerdoId);
      final compromisosRaw = await _compromisosService.listarCompromisosPorAcuerdo(widget.acuerdoId);
      
      // Convertir compromisos a Maps mutables
      final compromisos = compromisosRaw.map((c) => Map<String, dynamic>.from(c)).toList();
      
      // Enriquecer acuerdo con nombres
      final db = await AppDatabase.instance();
      final unidadId = acuerdo['unidad_gestion_id'] as int?;
      final entidadId = acuerdo['entidad_plantel_id'] as int?;
      
      if (unidadId != null) {
        final unidad = await db.query('unidades_gestion', where: 'id = ?', whereArgs: [unidadId]);
        if (unidad.isNotEmpty) {
          acuerdo['_unidad_nombre'] = unidad.first['nombre'];
        }
      }
      
      if (entidadId != null) {
        final entidad = await db.query('entidades_plantel', where: 'id = ?', whereArgs: [entidadId]);
        if (entidad.isNotEmpty) {
          acuerdo['_entidad_nombre'] = entidad.first['nombre'];
        }
      }
      
      // Enriquecer compromisos con estadísticas de cuotas
      for (final compromiso in compromisos) {
        final cuotasStats = await db.rawQuery('''
          SELECT 
            COUNT(*) as total,
            SUM(CASE WHEN estado = 'ESPERADO' THEN 1 ELSE 0 END) as esperadas,
            SUM(CASE WHEN estado = 'CONFIRMADO' THEN 1 ELSE 0 END) as confirmadas
          FROM compromiso_cuotas
          WHERE compromiso_id = ?
        ''', [compromiso['id']]);
        
        if (cuotasStats.isNotEmpty) {
          compromiso['_cuotas_stats'] = cuotasStats.first;
        }
      }
      
      // Cargar nombre de categoría
      String? catNombre;
      final codigoCat = acuerdo['categoria']?.toString();
      if (codigoCat != null && codigoCat.isNotEmpty && codigoCat != '-') {
        catNombre = await CategoriaMovimientoService.obtenerNombrePorCodigo(codigoCat);
      }
      
      // FASE 19: Cargar datos de origen grupal si aplica
      Map<String, dynamic>? historico;
      List<Map<String, dynamic>> hermanos = [];
      
      final acuerdoGrupalRef = acuerdo['acuerdo_grupal_ref']?.toString();
      if (acuerdoGrupalRef != null && acuerdoGrupalRef.isNotEmpty) {
        try {
          historico = await _grupalSvc.obtenerHistorico(acuerdoGrupalRef);
          final hermanosRaw = await _grupalSvc.listarAcuerdosHermanos(acuerdoGrupalRef);
          
          // Convertir a Maps mutables
          hermanos = hermanosRaw.map((h) => Map<String, dynamic>.from(h)).toList();
          
          // Enriquecer hermanos con nombres
          for (final hermano in hermanos) {
            final entidadId = hermano['entidad_plantel_id'] as int?;
            if (entidadId != null) {
              final entidad = await db.query('entidades_plantel', where: 'id = ?', whereArgs: [entidadId]);
              if (entidad.isNotEmpty) {
                hermano['_entidad_nombre'] = entidad.first['nombre'];
              }
            }
          }
        } catch (e, stack) {
          await AppDatabase.logLocalError(
            scope: 'detalle_acuerdo_page.cargar_origen_grupal',
            error: e.toString(),
            stackTrace: stack,
            payload: {'acuerdo_grupal_ref': acuerdoGrupalRef},
          );
          // No fallar por esto, solo no mostrar la sección
        }
      }
      
      setState(() {
        _acuerdo = acuerdo;
        _stats = stats;
        _compromisos = compromisos;
        _categoriaNombre = catNombre;
        _historico = historico;
        _acuerdosHermanos = hermanos;
        _isLoading = false;
      });
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'detalle_acuerdo_page.cargar_datos',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': widget.acuerdoId},
      );
      
      setState(() => _isLoading = false);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al cargar acuerdo'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _finalizarAcuerdo() async {
    try {
      // FASE 22.6: Consultar cuotas esperadas de compromisos asociados a este acuerdo
      final db = await AppDatabase.instance();
      
      // Obtener IDs de compromisos asociados al acuerdo
      final compromisosAsociados = await db.query(
        'compromisos',
        columns: ['id'],
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [widget.acuerdoId],
      );
      
      final compromisoIds = compromisosAsociados.map((c) => c['id'] as int).toList();
      
      // Consultar cuotas ESPERADO de esos compromisos
      final cuotasEsperadas = compromisoIds.isEmpty ? <Map<String, dynamic>>[] : await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id IN (${List.filled(compromisoIds.length, '?').join(',')}) AND estado = ?',
        whereArgs: [...compromisoIds, 'ESPERADO'],
      );
      
      // Diálogo con opciones si hay cuotas ESPERADO
      if (cuotasEsperadas.isNotEmpty) {
        final accion = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Finalizar Acuerdo'),
            content: Text(
              '¿Desea finalizar el acuerdo "${_acuerdo!['nombre']}"?\n\n'
              'Este acuerdo tiene ${cuotasEsperadas.length} cuota${cuotasEsperadas.length > 1 ? 's' : ''} en estado ESPERADO.\n\n'
              '¿Qué desea hacer con ellas?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'SOLO_FINALIZAR'),
                child: const Text('Solo finalizar acuerdo'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'FINALIZAR_Y_CANCELAR'),
                style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                child: const Text('Finalizar y cancelar cuotas'),
              ),
            ],
          ),
        );
        
        if (accion == null) return; // Usuario canceló
        
        // Finalizar acuerdo
        await AcuerdosService.finalizarAcuerdo(widget.acuerdoId);
        
        // Si eligió cancelar cuotas, hacerlo
        if (accion == 'FINALIZAR_Y_CANCELAR') {
          int cancelados = 0;
          
          for (final cuota in cuotasEsperadas) {
            final cuotaId = cuota['id'] as int;
            
            try {
              // Cambiar estado a CANCELADO
              await db.update(
                'compromiso_cuotas',
                {
                  'estado': 'CANCELADO',
                  'observacion_cancelacion': 'Cancelada por finalización de acuerdo',
                  'updated_ts': DateTime.now().millisecondsSinceEpoch,
                },
                where: 'id = ?',
                whereArgs: [cuotaId],
              );
              cancelados++;
            } catch (e) {
              // Continuar con las demás aunque falle una
              await AppDatabase.logLocalError(
                scope: 'detalle_acuerdo_page.cancelar_cuotas',
                error: e.toString(),
                payload: {'cuota_id': cuotaId},
              );
            }
          }
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Acuerdo finalizado. $cancelados cuota${cancelados > 1 ? 's' : ''} cancelada${cancelados > 1 ? 's' : ''}.')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Acuerdo finalizado. Cuotas ESPERADO permanecen activas.')),
            );
          }
        }
      } else {
        // No hay compromisos ESPERADO, solo confirmar finalización
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Finalizar Acuerdo'),
            content: Text(
              '¿Finalizar el acuerdo "${_acuerdo!['nombre']}"?\n\n'
              'Esto marcará el acuerdo como inactivo y no se generarán más compromisos.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Finalizar'),
              ),
            ],
          ),
        );
        
        if (confirm != true) return;
        
        await AcuerdosService.finalizarAcuerdo(widget.acuerdoId);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Acuerdo finalizado')),
          );
        }
      }
      
      if (mounted) {
        _cargarDatos();
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'detalle_acuerdo_page.finalizar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': widget.acuerdoId},
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _editarAcuerdo() async {
    // Verificar si tiene compromisos confirmados
    final cuotasConfirmadas = _stats?['cuotas_confirmadas'] as int? ?? 0;
    
    if (cuotasConfirmadas > 0) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No se puede editar'),
          content: const Text(
            'Este acuerdo ya tiene compromisos confirmados y no puede ser editado.\n\n'
            'Si necesita modificarlo, puede finalizarlo y crear uno nuevo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }
    
    final resultado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => EditarAcuerdoPage(acuerdoId: widget.acuerdoId),
      ),
    );
    
    if (resultado == true) {
      _cargarDatos();
    }
  }
  
  Future<void> _eliminarAcuerdo() async {
    try {
      // Primero validar si se puede eliminar
      final resultado = await AcuerdosService.eliminarAcuerdo(widget.acuerdoId);
      
      final puedeEliminar = resultado['puede_eliminar'] as bool;
      
      if (!puedeEliminar) {
        // Mostrar diálogo explicando por qué no se puede eliminar
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error, color: Colors.red, size: 32),
                SizedBox(width: 12),
                Text('No se puede eliminar'),
              ],
            ),
            content: Text(
              resultado['razon'] as String? ?? 'No se puede eliminar el acuerdo',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Entendido'),
              ),
            ],
          ),
        );
        return;
      }
      
      // Mostrar diálogo de confirmación
      final confirmar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning, color: Colors.orange, size: 32),
              SizedBox(width: 12),
              Text('Eliminar Acuerdo'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '¿Estás seguro de que querés eliminar el acuerdo "${_acuerdo!['nombre']}"?',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Esta acción:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text('• Marcará el acuerdo como eliminado'),
              const Text('• Eliminará todos los compromisos ESPERADO asociados'),
              const Text('• NO podrá deshacerse'),
              const SizedBox(height: 12),
              const Text(
                'Los compromisos ya confirmados y sus movimientos se conservan para auditoría.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      );
      
      if (confirmar != true) return;
      
      // Ya se eliminó en la validación, solo mostrar confirmación
      if (!mounted) return;
      
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 32),
              SizedBox(width: 12),
              Text('Acuerdo Eliminado'),
            ],
          ),
          content: const Text(
            'El acuerdo se eliminó correctamente.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );
      
      if (mounted) {
        // Volver a la lista de acuerdos
        Navigator.pop(context, true);
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'detalle_acuerdo_page.eliminar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': widget.acuerdoId},
      );
      
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error, color: Colors.red, size: 32),
                SizedBox(width: 12),
                Text('Error'),
              ],
            ),
            content: Text('No se pudo eliminar el acuerdo: ${e.toString()}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppBarBreadcrumb(
          items: [
            BreadcrumbItem(
              label: 'Acuerdos',
              icon: Icons.description,
              onTap: () => Navigator.of(context).popUntil((route) => route.isFirst),
            ),
            BreadcrumbItem(
              label: _acuerdo != null 
                ? (_acuerdo!['nombre'] as String? ?? 'Detalle')
                : 'Detalle',
            ),
          ],
        ),
        actions: [
          if (_acuerdo != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'editar':
                    _editarAcuerdo();
                    break;
                  case 'finalizar':
                    _finalizarAcuerdo();
                    break;
                  case 'eliminar':
                    _eliminarAcuerdo();
                    break;
                }
              },
              itemBuilder: (ctx) {
                final activo = (_acuerdo!['activo'] as int?) == 1;
                return [
                  if (activo)
                    const PopupMenuItem(
                      value: 'editar',
                      child: Row(
                        children: [
                          Icon(Icons.edit),
                          SizedBox(width: 8),
                          Text('Editar'),
                        ],
                      ),
                    ),
                  if (activo)
                    const PopupMenuItem(
                      value: 'finalizar',
                      child: Row(
                        children: [
                          Icon(Icons.stop),
                          SizedBox(width: 8),
                          Text('Finalizar'),
                        ],
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'eliminar',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Eliminar', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ];
              },
            ),
        ],
      ),
      body: _isLoading
          ? SkeletonLoader.list(count: 5)
          : ResponsiveContainer(
              maxWidth: 800,
              child: RefreshIndicator(
                onRefresh: _cargarDatos,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                  _buildInfoCard(),
                  const SizedBox(height: 16),
                  // FASE 19: Mostrar info de origen grupal si aplica
                  if (_historico != null) ...[
                    _buildOrigenGrupalCard(),
                    const SizedBox(height: 16),
                  ],
                  if (_acuerdosHermanos.isNotEmpty) ...[
                    _buildAcuerdosHermanosCard(),
                    const SizedBox(height: 16),
                  ],
                  _buildEstadisticasCard(),
                  const SizedBox(height: 16),
                  _buildCompromisosCard(),
                ],
              ),
            ),
            ),
    );
  }

  Widget _buildInfoCard() {
    final nombre = _acuerdo!['nombre']?.toString() ?? 'Sin nombre';
    final tipo = _acuerdo!['tipo']?.toString() ?? 'EGRESO';
    final modalidad = _acuerdo!['modalidad']?.toString() ?? 'RECURRENTE';
    final activo = (_acuerdo!['activo'] as int?) == 1;
    final categoria = _acuerdo!['categoria']?.toString() ?? '-';
    final fechaInicio = _acuerdo!['fecha_inicio']?.toString() ?? '-';
    final fechaFin = _acuerdo!['fecha_fin']?.toString();
    final observaciones = _acuerdo!['observaciones']?.toString();
    final unidadNombre = _acuerdo!['_unidad_nombre']?.toString() ?? 'Desconocida';
    final entidadNombre = _acuerdo!['_entidad_nombre']?.toString();
    final frecuencia = _acuerdo!['frecuencia']?.toString() ?? '-';
    final frecuenciaDias = _acuerdo!['frecuencia_dias'] as int?;
    
    final montoDisplay = modalidad == 'MONTO_TOTAL_CUOTAS'
        ? (_acuerdo!['monto_total'] as num?)?.toDouble() ?? 0.0
        : (_acuerdo!['monto_periodico'] as num?)?.toDouble() ?? 0.0;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  tipo == 'INGRESO' ? Icons.arrow_downward : Icons.arrow_upward,
                  color: tipo == 'INGRESO' ? Colors.green : Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nombre,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      if (!activo)
                        Chip(
                          label: const Text('Finalizado', style: TextStyle(fontSize: 11)),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Colors.grey.shade300,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            
            // Layout en 2 columnas
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Columna izquierda
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow('Unidad de Gestión', unidadNombre, Icons.business),
                      if (entidadNombre != null)
                        _buildInfoRow('Entidad', entidadNombre, Icons.person),
                      _buildInfoRow('Tipo', tipo, Icons.category),
                      _buildInfoRow('Categoría', _categoriaNombre ?? categoria, Icons.label),
                      _buildInfoRow('Fecha Inicio', fechaInicio, Icons.calendar_today),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Columna derecha
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow('Modalidad', _modalidadLabel(modalidad), Icons.payment),
                      _buildInfoRow('Monto', _fmtMonto(montoDisplay), Icons.attach_money),
                      _buildInfoRow('Frecuencia', frecuencia, Icons.schedule),
                      if (frecuenciaDias != null)
                        _buildInfoRow('Semanal', frecuenciaDias == 7 ? 'Sí' : 'No', Icons.event_repeat),
                      if (fechaFin != null)
                        _buildInfoRow('Fecha Fin', fechaFin, Icons.event),
                    ],
                  ),
                ),
              ],
            ),
            
            if (observaciones != null && observaciones.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                'Observaciones',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(observaciones),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEstadisticasCard() {
    final cuotasEsperadas = _stats?['cuotas_esperadas'] as int? ?? 0;
    final cuotasConfirmadas = _stats?['cuotas_confirmadas'] as int? ?? 0;
    final cuotasCanceladas = _stats?['cuotas_canceladas'] as int? ?? 0;
    final cuotasTotal = cuotasEsperadas + cuotasConfirmadas + cuotasCanceladas;
    final montoEsperado = (_stats?['monto_total_esperado'] as num?)?.toDouble() ?? 0.0;
    final montoConfirmado = (_stats?['monto_total_confirmado'] as num?)?.toDouble() ?? 0.0;
    
    final progreso = cuotasTotal > 0 ? cuotasConfirmadas / cuotasTotal : 0.0;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Estadísticas',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            
            LinearProgressIndicator(
              value: progreso,
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(
                _acuerdo!['tipo'] == 'INGRESO' ? Colors.green : Colors.blue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${(progreso * 100).toStringAsFixed(1)}% completado',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 24),
            
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    'Esperadas',
                    cuotasEsperadas.toString(),
                    Colors.orange,
                    Icons.schedule,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    'Confirmadas',
                    cuotasConfirmadas.toString(),
                    Colors.green,
                    Icons.check_circle,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    'Canceladas',
                    cuotasCanceladas.toString(),
                    Colors.red,
                    Icons.cancel,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      'Monto Esperado',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _fmtMonto(montoEsperado),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      'Monto Confirmado',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _fmtMonto(montoConfirmado),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildCompromisosCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compromisos Generados (${_compromisos.length})',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            
            if (_compromisos.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No hay compromisos generados'),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _compromisos.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final compromiso = _compromisos[index];
                  final stats = compromiso['_cuotas_stats'] as Map<String, dynamic>?;
                  final confirmadas = (stats?['confirmadas'] as int?) ?? 0;
                  final total = (stats?['total'] as int?) ?? 0;
                  
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text('${index + 1}'),
                    ),
                    title: Text(compromiso['nombre']?.toString() ?? 'Sin nombre'),
                    subtitle: Text(
                      'Cuotas: $confirmadas/$total confirmadas',
                    ),
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (ctx) => DetalleCompromisoPage(
                            compromisoId: compromiso['id'] as int,
                          ),
                        ),
                      ).then((_) => _cargarDatos());
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _modalidadLabel(String modalidad) {
    switch (modalidad) {
      case 'MONTO_TOTAL_CUOTAS':
        return 'Monto Total en Cuotas';
      case 'RECURRENTE':
        return 'Recurrente';
      default:
        return modalidad;
    }
  }
  
  // FASE 19: Card de información de origen grupal
  Widget _buildOrigenGrupalCard() {
    if (_historico == null) return const SizedBox.shrink();
    
    final nombreGrupal = _historico!['nombre']?.toString() ?? 'Sin nombre';
    final fechaCreacion = _historico!['created_ts'] as int?;
    final totalAcuerdos = _historico!['total_acuerdos'] as int? ?? 0;
    final totalCompromisos = _historico!['total_compromisos'] as int? ?? 0;
    
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.group, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Acuerdo Grupal',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade900,
                        ),
                  ),
                ),
              ],
            ),
            const Divider(),
            Text(
              'Este acuerdo fue creado como parte de "$nombreGrupal"',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 8),
            if (fechaCreacion != null)
              Text(
                'Creado: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.fromMillisecondsSinceEpoch(fechaCreacion))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Text(
              'Total de acuerdos generados: $totalAcuerdos',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'Total de compromisos generados: $totalCompromisos',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
  
  // FASE 19: Card de acuerdos hermanos (del mismo grupo)
  Widget _buildAcuerdosHermanosCard() {
    if (_acuerdosHermanos.isEmpty) return const SizedBox.shrink();
    
    // Filtrar el acuerdo actual
    final hermanos = _acuerdosHermanos
        .where((a) => (a['id'] as int) != widget.acuerdoId)
        .toList();
    
    if (hermanos.isEmpty) return const SizedBox.shrink();
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.people_outline),
                const SizedBox(width: 8),
                Text(
                  'Acuerdos del mismo grupo (${hermanos.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(),
            SizedBox(
              height: hermanos.length > 3 ? 200 : null,
              child: ListView.separated(
                shrinkWrap: hermanos.length <= 3,
                itemCount: hermanos.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final hermano = hermanos[index];
                  final entidadNombre = hermano['_entidad_nombre']?.toString() ?? 'Desconocido';
                  final activo = (hermano['activo'] as int?) == 1;
                  final monto = hermano['modalidad'] == 'MONTO_TOTAL_CUOTAS'
                      ? (hermano['monto_total'] as num?)?.toDouble() ?? 0.0
                      : (hermano['monto_periodico'] as num?)?.toDouble() ?? 0.0;
                  
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      activo ? Icons.check_circle : Icons.cancel,
                      color: activo ? Colors.green : Colors.grey,
                      size: 20,
                    ),
                    title: Text(
                      entidadNombre,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    subtitle: Text(_fmtMonto(monto)),
                    trailing: const Icon(Icons.arrow_forward, size: 16),
                    onTap: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (ctx) => DetalleAcuerdoPage(
                            acuerdoId: hermano['id'] as int,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
