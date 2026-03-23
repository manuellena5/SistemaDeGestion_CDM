import 'package:sqflite/sqflite.dart';
import '../../../data/dao/db.dart';
import '../../../domain/safe_map.dart';

/// FASE 18.3: Servicio para gestión de Acuerdos (reglas/contratos que generan compromisos)
/// 
/// Un acuerdo representa una regla o contrato económico que genera compromisos automáticamente.
/// Ej: Sueldo mensual de un DT, cuota de un jugador, etc.
/// 
/// Jerarquía conceptual:
/// - Acuerdo = regla / contrato / condición repetitiva
/// - Compromiso = expectativa futura concreta
/// - Movimiento = hecho real confirmado
class AcuerdosService {
  /// CRUD BÁSICO
  
  /// Crear un nuevo acuerdo
  /// 
  /// Validaciones:
  /// - unidad_gestion_id debe existir
  /// - fecha_inicio <= fecha_fin (si fecha_fin != null)
  /// - Si modalidad = MONTO_TOTAL_CUOTAS → monto_total y cuotas requeridos
  /// - Si modalidad = RECURRENTE → monto_periodico requerido
  /// - frecuencia debe existir en tabla frecuencias
  /// 
  /// Parámetros FASE 19:
  /// - origenGrupal: si fue creado desde un acuerdo grupal
  /// - acuerdoGrupalRef: UUID del acuerdo grupal origen
  /// - generaCompromisos: si debe generar compromisos automáticamente
  /// 
  /// Retorna: id del acuerdo creado
  static Future<int> crearAcuerdo({
    required int unidadGestionId,
    int? entidadPlantelId,
    required String nombre,
    required String tipo, // 'INGRESO' | 'EGRESO'
    required String modalidad, // 'MONTO_TOTAL_CUOTAS' | 'RECURRENTE'
    double? montoTotal,
    double? montoPeriodico,
    required String frecuencia,
    int? frecuenciaDias,
    int? cuotas,
    required String fechaInicio, // YYYY-MM-DD
    String? fechaFin, // YYYY-MM-DD
    required String categoria,
    String? observaciones,
    String? archivoLocalPath,
    String? archivoRemoteUrl,
    String? archivoNombre,
    String? archivoTipo,
    int? archivoSize,
    String? dispositivoId,
    bool origenGrupal = false,
    String? acuerdoGrupalRef,
    bool generaCompromisos = true,
    bool esAdhesion = false,
    String unidad = 'ARS',
    int? subcategoriaId,
    // Campos exclusivos de modalidad POR_EVENTO (v29+)
    bool esPorEvento = false,
    double? montoTitular,
    double? montoSuplente,
    double montoNoJugo = 0,
    int partidosEsperadosMes = 4,
  }) async {
    try {
      // Validaciones previas
      if (!['INGRESO', 'EGRESO'].contains(tipo)) {
        throw ArgumentError('Tipo debe ser INGRESO o EGRESO');
      }

      // Acuerdos POR_EVENTO: se guardan con modalidad='RECURRENTE' + es_por_evento=1
      // porque el CHECK de la DB no admite un tercer valor en modalidad (SQLite no
      // permite ALTER TABLE para modificar CHECKs existentes).
      if (esPorEvento) {
        if (montoTitular == null || montoTitular <= 0) {
          throw ArgumentError('Un acuerdo por partido requiere monto_titular > 0');
        }
        if (montoSuplente == null || montoSuplente < 0) {
          throw ArgumentError('Un acuerdo por partido requiere monto_suplente >= 0');
        }
        // Para POR_EVENTO no aplican validaciones de modalidad regular
      } else {
        if (!['MONTO_TOTAL_CUOTAS', 'RECURRENTE'].contains(modalidad)) {
          throw ArgumentError('Modalidad debe ser MONTO_TOTAL_CUOTAS o RECURRENTE');
        }

        if (modalidad == 'MONTO_TOTAL_CUOTAS') {
          if (montoTotal == null || cuotas == null) {
            throw ArgumentError('MONTO_TOTAL_CUOTAS requiere monto_total y cuotas');
          }
          if (montoTotal <= 0 || cuotas <= 0) {
            throw ArgumentError('monto_total y cuotas deben ser mayores a 0');
          }
        }

        if (modalidad == 'RECURRENTE') {
          if (montoPeriodico == null) {
            throw ArgumentError('RECURRENTE requiere monto_periodico');
          }
          if (montoPeriodico <= 0) {
            throw ArgumentError('monto_periodico debe ser mayor a 0');
          }
        }
      }
      
      if (fechaFin != null) {
        final inicio = DateTime.parse(fechaInicio);
        final fin = DateTime.parse(fechaFin);
        if (fin.isBefore(inicio)) {
          throw ArgumentError('fecha_fin debe ser >= fecha_inicio');
        }
      }
      
      final db = await AppDatabase.instance();
      
      // Validar que unidad_gestion_id existe
      final unidadExists = await db.query(
        'unidades_gestion',
        where: 'id = ?',
        whereArgs: [unidadGestionId],
      );
      if (unidadExists.isEmpty) {
        throw ArgumentError('unidad_gestion_id $unidadGestionId no existe');
      }
      
      // Validar que entidad_plantel_id existe (si se proporciona)
      if (entidadPlantelId != null) {
        final entidadExists = await db.query(
          'entidades_plantel',
          where: 'id = ?',
          whereArgs: [entidadPlantelId],
        );
        if (entidadExists.isEmpty) {
          throw ArgumentError('entidad_plantel_id $entidadPlantelId no existe');
        }
      }
      
      // Validar que frecuencia existe
      final frecuenciaExists = await db.query(
        'frecuencias',
        where: 'codigo = ?',
        whereArgs: [frecuencia],
      );
      if (frecuenciaExists.isEmpty) {
        throw ArgumentError('frecuencia $frecuencia no existe');
      }
      
      final now = DateTime.now().millisecondsSinceEpoch;
      
      // Para POR_EVENTO: guardar como RECURRENTE en DB (check constraint),
      // diferenciado por es_por_evento=1 y frecuencia='POR_EVENTO'.
      final modalidadDb = esPorEvento ? 'RECURRENTE' : modalidad;
      final frecuenciaDb = esPorEvento ? 'POR_EVENTO' : frecuencia;

      final id = await db.insert('acuerdos', {
        'unidad_gestion_id': unidadGestionId,
        'entidad_plantel_id': entidadPlantelId,
        'nombre': nombre,
        'tipo': tipo,
        'modalidad': modalidadDb,
        'monto_total': montoTotal,
        // POR_EVENTO: usar monto_titular como monto_periodico para satisfacer el CHECK constraint
        'monto_periodico': esPorEvento ? montoTitular : montoPeriodico,
        'frecuencia': frecuenciaDb,
        'frecuencia_dias': frecuenciaDias,
        'cuotas': cuotas,
        'fecha_inicio': fechaInicio,
        'fecha_fin': fechaFin,
        'categoria': categoria,
        'observaciones': observaciones,
        'activo': 1,
        'archivo_local_path': archivoLocalPath,
        'archivo_remote_url': archivoRemoteUrl,
        'archivo_nombre': archivoNombre,
        'archivo_tipo': archivoTipo,
        'archivo_size': archivoSize,
        'dispositivo_id': dispositivoId,
        'origen_grupal': origenGrupal ? 1 : 0,
        'acuerdo_grupal_ref': acuerdoGrupalRef,
        'es_adhesion': esAdhesion ? 1 : 0,
        'subcategoria_id': subcategoriaId,
        'unidad': unidad,
        'version_actual': 1,
        'fecha_vigencia_desde': fechaInicio,
        'eliminado': 0,
        'sync_estado': 'PENDIENTE',
        'created_ts': now,
        'updated_ts': now,
        // Campos POR_EVENTO (v29+)
        'es_por_evento': esPorEvento ? 1 : 0,
        'monto_titular': esPorEvento ? montoTitular : null,
        'monto_suplente': esPorEvento ? montoSuplente : null,
        'monto_no_jugo': esPorEvento ? montoNoJugo : 0,
        'partidos_esperados_mes': esPorEvento ? partidosEsperadosMes : null,
      });
      
      // Crear versión inicial en acuerdos_versiones
      await db.insert('acuerdos_versiones', {
        'acuerdo_id': id,
        'version': 1,
        'modalidad': modalidadDb,
        'monto_total': montoTotal,
        'monto_periodico': esPorEvento ? montoTitular : montoPeriodico,
        'frecuencia': frecuenciaDb,
        'frecuencia_dias': frecuenciaDias,
        'cuotas': cuotas,
        'fecha_vigencia_desde': fechaInicio,
        'fecha_vigencia_hasta': null,
        'motivo_cambio': 'Versión inicial',
        'dispositivo_id': dispositivoId,
        'created_ts': now,
      });

      // Generar compromisos automáticamente si se solicitó (no aplica a acuerdos POR_EVENTO)
      if (generaCompromisos && !esPorEvento) {
        await generarCompromisos(id);
      }
      
      return id;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.crear_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'nombre': nombre, 'unidad_gestion_id': unidadGestionId},
      );
      rethrow;
    }
  }
  
  /// Obtener un acuerdo por ID
  static Future<Map<String, dynamic>?> obtenerAcuerdo(int id) async {
    try {
      final db = await AppDatabase.instance();
      final result = await db.query(
        'acuerdos',
        where: 'id = ? AND eliminado = 0',
        whereArgs: [id],
      );
      
      if (result.isEmpty) return null;
      
      return result.first;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.obtener_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );
      rethrow;
    }
  }
  
  /// Listar acuerdos con filtros opcionales
  static Future<List<Map<String, dynamic>>> listarAcuerdos({
    int? unidadGestionId,
    int? entidadPlantelId,
    String? tipo,
    String? categoria,
    bool? soloActivos,
    bool incluirEliminados = false,
    String? acuerdoGrupalRef,
  }) async {
    try {
      final db = await AppDatabase.instance();
      
      final where = <String>[];
      final whereArgs = <dynamic>[];
      
      if (unidadGestionId != null) {
        where.add('unidad_gestion_id = ?');
        whereArgs.add(unidadGestionId);
      }
      
      if (entidadPlantelId != null) {
        where.add('entidad_plantel_id = ?');
        whereArgs.add(entidadPlantelId);
      }
      
      if (tipo != null) {
        where.add('tipo = ?');
        whereArgs.add(tipo);
      }
      
      if (categoria != null) {
        where.add('categoria = ?');
        whereArgs.add(categoria);
      }
      
      if (soloActivos != null && soloActivos) {
        where.add('activo = 1');
      }
      
      if (acuerdoGrupalRef != null) {
        where.add('acuerdo_grupal_ref = ?');
        whereArgs.add(acuerdoGrupalRef);
      }
      
      if (!incluirEliminados) {
        where.add('eliminado = 0');
      }
      
      final result = await db.query(
        'acuerdos',
        where: where.isNotEmpty ? where.join(' AND ') : null,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'created_ts DESC',
      );
      
      return result;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.listar_acuerdos',
        error: e.toString(),
        stackTrace: stack,
        payload: {
          'unidad_gestion_id': unidadGestionId,
          'tipo': tipo,
          'categoria': categoria,
          'solo_activos': soloActivos,
          'acuerdo_grupal_ref': acuerdoGrupalRef,
        },
      );
      rethrow;
    }
  }
  
  /// Actualizar un acuerdo existente
  /// 
  /// Validación crítica: NO permite editar si el acuerdo tiene compromisos CONFIRMADO
  /// Actualizar acuerdo (con versionado para cambios de monto/frecuencia/modalidad)
  /// 
  /// REGLA NO NEGOCIABLE: No modificar datos pasados (compromisos confirmados).
  /// 
  /// Si se modifica monto/frecuencia/modalidad:
  /// - Crea nueva versión con fecha_vigencia_desde = hoy
  /// - Cierra versión anterior (fecha_vigencia_hasta = ayer)
  /// - Futuros compromisos usarán nueva versión
  /// - Compromisos pasados permanecen con versión anterior
  /// 
  /// Parámetros que crean nueva versión:
  /// - modalidad, montoTotal, montoPeriodico, frecuencia, frecuenciaDias, cuotas
  /// 
  /// Parámetros que NO crean versión (actualización simple):
  /// - nombre, fechaFin, observaciones, archivos
  static Future<void> actualizarAcuerdo({
    required int id,
    String? nombre,
    String? modalidad,
    double? montoTotal,
    double? montoPeriodico,
    String? frecuencia,
    int? frecuenciaDias,
    int? cuotas,
    String? fechaFin,
    String? observaciones,
    String? motivoCambio, // Requerido si hay cambios que crean versión
    String? categoria,
    int? subcategoriaId,
    String? archivoLocalPath,
    String? archivoRemoteUrl,
    String? archivoNombre,
    String? archivoTipo,
    int? archivoSize,
  }) async {
    try {
      final db = await AppDatabase.instance();
      
      // Validar que el acuerdo existe
      final acuerdo = await obtenerAcuerdo(id);
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $id no existe');
      }
      
      // REGLA NO NEGOCIABLE: No editar acuerdos con compromisos confirmados EN EL PASADO
      final compromisosConfirmados = await db.rawQuery('''
        SELECT COUNT(*) as count
        FROM compromisos c
        INNER JOIN compromiso_cuotas cc ON cc.compromiso_id = c.id
        WHERE c.acuerdo_id = ? AND cc.estado = 'CONFIRMADO'
      ''', [id]);
      
      final countConfirmados = compromisosConfirmados.first.safeInt('count');
      
      // Detectar si hay cambios que requieren versionado
      final cambiosVersionables = modalidad != null ||
          montoTotal != null ||
          montoPeriodico != null ||
          frecuencia != null ||
          frecuenciaDias != null ||
          cuotas != null;
      
      if (cambiosVersionables) {
        // VALIDACIÓN: Si hay compromisos confirmados, solo podemos crear nueva versión
        if (countConfirmados > 0 && motivoCambio == null) {
          throw ArgumentError(
            'Debe proporcionar motivo_cambio para modificar un acuerdo con compromisos confirmados'
          );
        }
        
        // Crear nueva versión
        await _crearNuevaVersionAcuerdo(
          db: db,
          acuerdoId: id,
          acuerdoActual: acuerdo,
          nuevaModalidad: modalidad,
          nuevoMontoTotal: montoTotal,
          nuevoMontoPeriodico: montoPeriodico,
          nuevaFrecuencia: frecuencia,
          nuevosFrecuenciaDias: frecuenciaDias,
          nuevasCuotas: cuotas,
          motivoCambio: motivoCambio ?? 'Modificación de parámetros',
        );
      }
      
      // Actualización simple de campos no versionables
      final updates = <String, dynamic>{};
      
      if (nombre != null) updates['nombre'] = nombre;
      if (categoria != null) updates['categoria'] = categoria;
      if (subcategoriaId != null) updates['subcategoria_id'] = subcategoriaId;
      if (fechaFin != null) {
        // Validar fecha_fin >= fecha_inicio
        final fechaInicio = DateTime.parse(acuerdo.safeString('fecha_inicio'));
        final fechaFinDate = DateTime.parse(fechaFin);
        if (fechaFinDate.isBefore(fechaInicio)) {
          throw ArgumentError('fecha_fin debe ser >= fecha_inicio');
        }
        updates['fecha_fin'] = fechaFin;
      }
      if (observaciones != null) updates['observaciones'] = observaciones;
      if (archivoLocalPath != null) updates['archivo_local_path'] = archivoLocalPath;
      if (archivoRemoteUrl != null) updates['archivo_remote_url'] = archivoRemoteUrl;
      if (archivoNombre != null) updates['archivo_nombre'] = archivoNombre;
      if (archivoTipo != null) updates['archivo_tipo'] = archivoTipo;
      if (archivoSize != null) updates['archivo_size'] = archivoSize;
      
      if (updates.isNotEmpty) {
        updates['updated_ts'] = DateTime.now().millisecondsSinceEpoch;
        updates['sync_estado'] = 'PENDIENTE';
        
        await db.update(
          'acuerdos',
          updates,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.actualizar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Crea una nueva versión de un acuerdo (uso interno)
  static Future<void> _crearNuevaVersionAcuerdo({
    required Database db,
    required int acuerdoId,
    required Map<String, dynamic> acuerdoActual,
    String? nuevaModalidad,
    double? nuevoMontoTotal,
    double? nuevoMontoPeriodico,
    String? nuevaFrecuencia,
    int? nuevosFrecuenciaDias,
    int? nuevasCuotas,
    required String motivoCambio,
  }) async {
    final now = DateTime.now();
    final hoy = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    
    final ayer = now.subtract(const Duration(days: 1));
    final ayerStr = '${ayer.year.toString().padLeft(4, '0')}-'
        '${ayer.month.toString().padLeft(2, '0')}-'
        '${ayer.day.toString().padLeft(2, '0')}';
    
    final versionActual = acuerdoActual.safeInt('version_actual', 1);
    final nuevaVersion = versionActual + 1;
    
    // 1) Cerrar versión anterior (fecha_vigencia_hasta = ayer)
    await db.update(
      'acuerdos_versiones',
      {'fecha_vigencia_hasta': ayerStr},
      where: 'acuerdo_id = ? AND version = ?',
      whereArgs: [acuerdoId, versionActual],
    );
    
    // 2) Crear nueva versión
    await db.insert('acuerdos_versiones', {
      'acuerdo_id': acuerdoId,
      'version': nuevaVersion,
      'modalidad': nuevaModalidad ?? acuerdoActual['modalidad'],
      'monto_total': nuevoMontoTotal ?? acuerdoActual['monto_total'],
      'monto_periodico': nuevoMontoPeriodico ?? acuerdoActual['monto_periodico'],
      'frecuencia': nuevaFrecuencia ?? acuerdoActual['frecuencia'],
      'frecuencia_dias': nuevosFrecuenciaDias ?? acuerdoActual['frecuencia_dias'],
      'cuotas': nuevasCuotas ?? acuerdoActual['cuotas'],
      'fecha_vigencia_desde': hoy,
      'fecha_vigencia_hasta': null,
      'motivo_cambio': motivoCambio,
      'dispositivo_id': acuerdoActual['dispositivo_id'],
      'created_ts': DateTime.now().millisecondsSinceEpoch,
    });
    
    // 3) Actualizar acuerdo principal con nueva versión y datos
    await db.update(
      'acuerdos',
      {
        'version_actual': nuevaVersion,
        'fecha_vigencia_desde': hoy,
        'modalidad': nuevaModalidad ?? acuerdoActual['modalidad'],
        'monto_total': nuevoMontoTotal ?? acuerdoActual['monto_total'],
        'monto_periodico': nuevoMontoPeriodico ?? acuerdoActual['monto_periodico'],
        'frecuencia': nuevaFrecuencia ?? acuerdoActual['frecuencia'],
        'frecuencia_dias': nuevosFrecuenciaDias ?? acuerdoActual['frecuencia_dias'],
        'cuotas': nuevasCuotas ?? acuerdoActual['cuotas'],
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        'sync_estado': 'PENDIENTE',
      },
      where: 'id = ?',
      whereArgs: [acuerdoId],
    );
  }

  /// Obtener historial de versiones de un acuerdo
  static Future<List<Map<String, dynamic>>> obtenerVersionesAcuerdo(int acuerdoId) async {
    try {
      final db = await AppDatabase.instance();
      final versiones = await db.query(
        'acuerdos_versiones',
        where: 'acuerdo_id = ?',
        whereArgs: [acuerdoId],
        orderBy: 'version ASC',
      );
      return versiones;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.obtener_versiones',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': acuerdoId},
      );
      rethrow;
    }
  }
  
  /// Finalizar un acuerdo (marcar como inactivo con fecha_fin = hoy)
  /// 
  /// Útil cuando el acuerdo ya tiene compromisos confirmados y no puede editarse.
  /// Marca activo=0 y establece fecha_fin si no existe.
  static Future<void> finalizarAcuerdo(int id) async {
    try {
      final db = await AppDatabase.instance();
      
      final acuerdo = await obtenerAcuerdo(id);
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $id no existe');
      }
      
      final now = DateTime.now();
      final today = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      
      await db.update(
        'acuerdos',
        {
          'activo': 0,
          'fecha_fin': acuerdo['fecha_fin'] ?? today,
          'updated_ts': now.millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.finalizar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );
      rethrow;
    }
  }
  
  /// Desactivar un acuerdo (soft delete)
  /// 
  /// Marca eliminado=1 y activo=0.
  /// NO elimina físicamente de la base de datos (política de auditoría).
  static Future<void> desactivarAcuerdo(int id) async {
    try {
      final db = await AppDatabase.instance();
      
      final acuerdo = await obtenerAcuerdo(id);
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $id no existe');
      }
      
      await db.update(
        'acuerdos',
        {
          'eliminado': 1,
          'activo': 0,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.desactivar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );
      rethrow;
    }
  }
  
  /// Eliminar un acuerdo (soft delete con validaciones)
  /// 
  /// Validaciones:
  /// - NO debe tener compromisos confirmados
  /// - NO debe tener movimientos asociados
  /// 
  /// Si pasa las validaciones, marca eliminado=1 y activo=0.
  /// NO elimina físicamente de la base de datos (política de auditoría).
  /// 
  /// Retorna: Map con resultado de validaciones:
  ///   - 'puede_eliminar': bool
  ///   - 'razon': String? (si no puede eliminar)
  ///   - 'compromisos_confirmados': int
  ///   - 'movimientos': int
  static Future<Map<String, dynamic>> eliminarAcuerdo(int id) async {
    try {
      final db = await AppDatabase.instance();
      
      final acuerdo = await obtenerAcuerdo(id);
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $id no existe');
      }
      
      // Validar: contar compromisos que tienen cuotas confirmadas asociados a este acuerdo
      final compromisosConfirmados = await db.rawQuery(
        'SELECT COUNT(DISTINCT cc.compromiso_id) as total '
        'FROM compromiso_cuotas cc '
        'JOIN compromisos c ON c.id = cc.compromiso_id '
        'WHERE c.acuerdo_id = ? AND cc.estado = ? AND c.eliminado = 0',
        [id, 'CONFIRMADO'],
      );
      final totalConfirmados = (compromisosConfirmados.first['total'] as int?) ?? 0;
      
      // Validar: contar movimientos asociados a compromisos de este acuerdo
      final movimientos = await db.rawQuery(
        'SELECT COUNT(*) as total FROM evento_movimiento '
        'WHERE compromiso_id IN '
        '(SELECT id FROM compromisos WHERE acuerdo_id = ? AND eliminado = 0)',
        [id],
      );
      final totalMovimientos = (movimientos.first['total'] as int?) ?? 0;
      
      // Si tiene compromisos confirmados o movimientos, no se puede eliminar
      if (totalConfirmados > 0) {
        return {
          'puede_eliminar': false,
          'razon': 'El acuerdo tiene $totalConfirmados compromiso(s) confirmado(s) y no puede ser eliminado',
          'compromisos_confirmados': totalConfirmados,
          'movimientos': totalMovimientos,
        };
      }
      
      if (totalMovimientos > 0) {
        return {
          'puede_eliminar': false,
          'razon': 'El acuerdo tiene $totalMovimientos movimiento(s) asociado(s) y no puede ser eliminado',
          'compromisos_confirmados': totalConfirmados,
          'movimientos': totalMovimientos,
        };
      }
      
      // Puede eliminar: hacer soft delete
      await db.update(
        'acuerdos',
        {
          'eliminado': 1,
          'activo': 0,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      
      // También marcar como eliminados los compromisos sin cuotas confirmadas asociados
      await db.update(
        'compromisos',
        {
          'eliminado': 1,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [id],
      );
      
      return {
        'puede_eliminar': true,
        'razon': null,
        'compromisos_confirmados': 0,
        'movimientos': 0,
      };
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.eliminar_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'id': id},
      );
      rethrow;
    }
  }
  
  /// GENERACIÓN DE COMPROMISOS
  
  /// Generar preview de compromisos que se crearían desde un acuerdo
  /// 
  /// NO inserta en base de datos, solo retorna lista de compromisos simulados.
  /// Útil para mostrar al usuario antes de confirmar.
  /// 
  /// Retorna: Lista de maps con estructura de compromiso
  static Future<List<Map<String, dynamic>>> previewCompromisos(int acuerdoId) async {
    try {
      final acuerdo = await obtenerAcuerdo(acuerdoId);
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $acuerdoId no existe');
      }

      // Acuerdos POR_EVENTO no generan cuotas predefinidas — los pagos se
      // crean manualmente por cada partido real en evento_movimiento.
      if ((acuerdo['es_por_evento'] as int? ?? 0) == 1) {
        return [];
      }

      final modalidad = acuerdo.safeString('modalidad');
      final fechaInicio = DateTime.parse(acuerdo.safeString('fecha_inicio'));
      final fechaFin = acuerdo.safeStringOrNull('fecha_fin') != null
          ? DateTime.parse(acuerdo.safeString('fecha_fin'))
          : null;
      
      final db = await AppDatabase.instance();
      final frecuenciaData = await db.query(
        'frecuencias',
        where: 'codigo = ?',
        whereArgs: [acuerdo['frecuencia']],
      );
      
      if (frecuenciaData.isEmpty) {
        throw StateError('Frecuencia ${acuerdo['frecuencia']} no encontrada');
      }
      
      final frecuenciaDias = frecuenciaData.first.safeIntOrNull('dias');
      if (frecuenciaDias == null) {
        throw StateError('Frecuencia ${acuerdo['frecuencia']} no tiene días definidos');
      }
      
      final compromisos = <Map<String, dynamic>>[];
      
      if (modalidad == 'MONTO_TOTAL_CUOTAS') {
        final montoTotal = acuerdo.safeDouble('monto_total');
        final cuotas = acuerdo.safeInt('cuotas', 1);
        final montoCuota = montoTotal / cuotas;
        
        for (int i = 0; i < cuotas; i++) {
          final fechaProgramada = fechaInicio.add(Duration(days: frecuenciaDias * i));
          
          // Si hay fecha_fin, no generar compromisos posteriores
          if (fechaFin != null && fechaProgramada.isAfter(fechaFin)) {
            break;
          }
          
          compromisos.add({
            'numero_cuota': i + 1,
            'fecha_programada': _formatDate(fechaProgramada),
            'monto': montoCuota,
            'nombre': '${acuerdo['nombre']} - Cuota ${i + 1}/$cuotas',
          });
        }
      } else if (modalidad == 'RECURRENTE') {
        final montoPeriodico = acuerdo.safeDouble('monto_periodico');
        
        var fechaActual = fechaInicio;
        var cuotaNum = 1;
        
        // Generar hasta fecha_fin o máximo 120 cuotas (10 años para prevenir loops infinitos)
        while (cuotaNum <= 120) {
          if (fechaFin != null && fechaActual.isAfter(fechaFin)) {
            break;
          }
          
          compromisos.add({
            'numero_cuota': cuotaNum,
            'fecha_programada': _formatDate(fechaActual),
            'monto': montoPeriodico,
            'nombre': '${acuerdo['nombre']} - ${_formatDate(fechaActual)}',
          });
          
          fechaActual = fechaActual.add(Duration(days: frecuenciaDias));
          cuotaNum++;
        }
      }
      
      return compromisos;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.preview_compromisos',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': acuerdoId},
      );
      rethrow;
    }
  }
  
  /// Generar compromisos reales en base de datos desde un acuerdo
  /// 
  /// IMPORTANTE: Solo genera compromisos que NO existan aún.
  /// No duplica compromisos ya creados.
  /// 
  /// Retorna: cantidad de compromisos generados
  static Future<int> generarCompromisos(int acuerdoId) async {
    try {
      final db = await AppDatabase.instance();
      final acuerdo = await obtenerAcuerdo(acuerdoId);
      
      if (acuerdo == null) {
        throw ArgumentError('Acuerdo $acuerdoId no existe');
      }
      
      final preview = await previewCompromisos(acuerdoId);
      
      if (preview.isEmpty) {
        return 0;
      }
      
      // Crear el compromiso padre (uno solo para todo el acuerdo)
      final now = DateTime.now().millisecondsSinceEpoch;
      
      final compromisoId = await db.insert('compromisos', {
        'acuerdo_id': acuerdoId,
        'unidad_gestion_id': acuerdo['unidad_gestion_id'],
        'entidad_plantel_id': acuerdo['entidad_plantel_id'],
        'nombre': acuerdo['nombre'],
        'tipo': acuerdo['tipo'],
        'modalidad': acuerdo['modalidad'],
        'monto': acuerdo['modalidad'] == 'MONTO_TOTAL_CUOTAS' 
            ? acuerdo['monto_total'] 
            : acuerdo['monto_periodico'],
        'frecuencia': acuerdo['frecuencia'],
        'frecuencia_dias': acuerdo['frecuencia_dias'],
        'cuotas': preview.length,
        'cuotas_confirmadas': 0,
        'fecha_inicio': acuerdo['fecha_inicio'],
        'fecha_fin': acuerdo['fecha_fin'],
        'categoria': acuerdo['categoria'],
        'observaciones': acuerdo['observaciones'],
        'activo': 1,
        'dispositivo_id': acuerdo['dispositivo_id'],
        'eliminado': 0,
        'sync_estado': 'PENDIENTE',
        'created_ts': now,
        'updated_ts': now,
      });
      
      // Insertar cuotas
      final batch = db.batch();
      
      for (final item in preview) {
        batch.insert('compromiso_cuotas', {
          'compromiso_id': compromisoId,
          'numero_cuota': item['numero_cuota'],
          'fecha_programada': item['fecha_programada'],
          'monto_esperado': item['monto'],
          'estado': 'ESPERADO',
          'created_ts': now,
          'updated_ts': now,
        });
      }
      
      await batch.commit(noResult: true);
      
      return preview.length;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.generar_compromisos',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': acuerdoId},
      );
      rethrow;
    }
  }
  
  /// Obtener estadísticas de un acuerdo
  /// 
  /// Retorna: {
  ///   'compromisos_generados': int,
  ///   'cuotas_esperadas': int,
  ///   'cuotas_confirmadas': int,
  ///   'cuotas_canceladas': int,
  ///   'monto_total_esperado': double,
  ///   'monto_total_confirmado': double,
  /// }
  static Future<Map<String, dynamic>> obtenerEstadisticasAcuerdo(int acuerdoId) async {
    try {
      final db = await AppDatabase.instance();
      
      final compromisosGenerados = await db.rawQuery('''
        SELECT COUNT(DISTINCT c.id) as count
        FROM compromisos c
        WHERE c.acuerdo_id = ? AND c.eliminado = 0
      ''', [acuerdoId]);
      
      final cuotasStats = await db.rawQuery('''
        SELECT 
          COUNT(*) as total,
          SUM(CASE WHEN estado = 'ESPERADO' THEN 1 ELSE 0 END) as esperadas,
          SUM(CASE WHEN estado = 'CONFIRMADO' THEN 1 ELSE 0 END) as confirmadas,
          SUM(CASE WHEN estado = 'CANCELADO' THEN 1 ELSE 0 END) as canceladas,
          SUM(monto_esperado) as monto_esperado,
          SUM(CASE WHEN estado = 'CONFIRMADO' THEN COALESCE(monto_real, monto_esperado) ELSE 0 END) as monto_confirmado
        FROM compromiso_cuotas cc
        INNER JOIN compromisos c ON c.id = cc.compromiso_id
        WHERE c.acuerdo_id = ?
      ''', [acuerdoId]);
      
      final stats = cuotasStats.first;
      
      return {
        'compromisos_generados': compromisosGenerados.first.safeInt('count'),
        'cuotas_esperadas': stats.safeInt('esperadas'),
        'cuotas_confirmadas': stats.safeInt('confirmadas'),
        'cuotas_canceladas': stats.safeInt('canceladas'),
        'monto_total_esperado': stats.safeDouble('monto_esperado'),
        'monto_total_confirmado': stats.safeDouble('monto_confirmado'),
      };
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'acuerdos_service.obtener_estadisticas_acuerdo',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdo_id': acuerdoId},
      );
      rethrow;
    }
  }
  
  /// Helper: formatear fecha como YYYY-MM-DD
  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
