import 'package:sqflite/sqflite.dart';

import '../../../data/dao/db.dart';
import '../../../domain/paginated_result.dart';
import '../../../domain/safe_map.dart';

/// FASE 13.4: Servicio para gestionar compromisos financieros
/// (obligaciones recurrentes como sueldos, sponsors, seguros).
///
/// Responsabilidades:
/// - CRUD de compromisos
/// - Validaciones de negocio
/// - Cálculos de vencimientos y cuotas
///
/// Reglas:
/// - Solo soft delete (eliminado=1), nunca borrado físico
/// - No desactivar si tiene movimientos ESPERADOS pendientes
/// - fecha_inicio <= fecha_fin
/// - monto > 0
class CompromisosService {
  CompromisosService._();
  static final instance = CompromisosService._();

  /// Crea un nuevo compromiso con validaciones.
  ///
  /// Retorna el ID del compromiso creado.
  ///
  /// Lanza excepción si:
  /// - unidad_gestion_id no existe o está inactiva
  /// - fecha_fin < fecha_inicio
  /// - monto <= 0
  /// - frecuencia no existe en catálogo
  /// - modalidad inválida
  ///
  /// FASE 18: Nuevo parámetro opcional acuerdoId para vincular con acuerdos
  Future<int> crearCompromiso({
    int? acuerdoId,
    required int unidadGestionId,
    required String nombre,
    required String tipo, // 'INGRESO' | 'EGRESO'
    required String
        modalidad, // 'PAGO_UNICO' | 'MONTO_TOTAL_CUOTAS' | 'RECURRENTE'
    required double monto,
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
    int? entidadPlantelId,
  }) async {
    try {
      // Validaciones
      if (monto <= 0) {
        throw ArgumentError('El monto debe ser mayor a cero');
      }

      if (!['INGRESO', 'EGRESO'].contains(tipo)) {
        throw ArgumentError('Tipo inválido. Debe ser INGRESO o EGRESO');
      }

      if (!['PAGO_UNICO', 'MONTO_TOTAL_CUOTAS', 'RECURRENTE']
          .contains(modalidad)) {
        throw ArgumentError(
            'Modalidad inválida. Debe ser PAGO_UNICO, MONTO_TOTAL_CUOTAS o RECURRENTE');
      }

      if (fechaFin != null && fechaFin.compareTo(fechaInicio) < 0) {
        throw ArgumentError(
            'La fecha de fin debe ser posterior a la fecha de inicio');
      }

      // Validación específica por modalidad
      if (modalidad == 'MONTO_TOTAL_CUOTAS' &&
          (cuotas == null || cuotas <= 0)) {
        throw ArgumentError(
            'La modalidad MONTO_TOTAL_CUOTAS requiere cantidad de cuotas válida');
      }

      final db = await AppDatabase.instance();

      // Validar que unidad_gestion existe y está activa
      final unidad = await db.query(
        'unidades_gestion',
        where: 'id = ? AND activo = 1',
        whereArgs: [unidadGestionId],
        limit: 1,
      );
      if (unidad.isEmpty) {
        throw ArgumentError('La unidad de gestión no existe o está inactiva');
      }

      // Validar que frecuencia existe
      final frec = await db.query(
        'frecuencias',
        where: 'codigo = ?',
        whereArgs: [frecuencia],
        limit: 1,
      );
      if (frec.isEmpty) {
        throw ArgumentError('Frecuencia inválida: $frecuencia');
      }

      final now = DateTime.now().millisecondsSinceEpoch;

      final id = await db.insert('compromisos', {
        'acuerdo_id': acuerdoId,
        'unidad_gestion_id': unidadGestionId,
        'nombre': nombre,
        'tipo': tipo,
        'modalidad': modalidad,
        'monto': monto,
        'frecuencia': frecuencia,
        'frecuencia_dias': frecuenciaDias,
        'cuotas': cuotas,
        'cuotas_confirmadas': 0,
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
        'entidad_plantel_id': entidadPlantelId,
        'eliminado': 0,
        'sync_estado': 'PENDIENTE',
        'created_ts': now,
        'updated_ts': now,
      });

      return id;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.crear',
        error: e,
        stackTrace: st,
        payload: {'unidadGestionId': unidadGestionId, 'nombre': nombre},
      );
      rethrow;
    }
  }

  /// Obtiene un compromiso por ID.
  ///
  /// Retorna null si no existe o está eliminado.
  Future<Map<String, dynamic>?> obtenerCompromiso(int id) async {
    try {
      final db = await AppDatabase.instance();
      final rows = await db.rawQuery('''
        SELECT c.*, ep.nombre as entidad_nombre
        FROM compromisos c
        LEFT JOIN entidades_plantel ep ON ep.id = c.entidad_plantel_id
        WHERE c.id = ? AND c.eliminado = 0
        LIMIT 1
      ''', [id]);
      return rows.isEmpty ? null : rows.first;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.obtener',
        error: e,
        stackTrace: st,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Lista compromisos con filtros opcionales.
  ///
  /// Parámetros:
  /// - [unidadGestionId]: filtrar por unidad de gestión
  /// - [tipo]: filtrar por INGRESO o EGRESO
  /// - [activo]: true = solo activos, false = solo pausados, null = todos
  /// - [incluirEliminados]: incluir compromisos con eliminado=1 (default false)
  ///
  /// Retorna lista ordenada por fecha_inicio DESC.
  Future<List<Map<String, dynamic>>> listarCompromisos({
    int? unidadGestionId,
    int? entidadPlantelId,
    String? tipo,
    String? estado,
    bool? activo,
    bool incluirEliminados = false,
  }) async {
    try {
      final db = await AppDatabase.instance();

      final whereConditions = <String>[];
      final whereArgs = <dynamic>[];

      if (!incluirEliminados) {
        whereConditions.add('eliminado = 0');
      }

      if (unidadGestionId != null) {
        whereConditions.add('unidad_gestion_id = ?');
        whereArgs.add(unidadGestionId);
      }

      if (entidadPlantelId != null) {
        whereConditions.add('entidad_plantel_id = ?');
        whereArgs.add(entidadPlantelId);
      }

      if (tipo != null) {
        whereConditions.add('tipo = ?');
        whereArgs.add(tipo);
      }

      if (estado != null) {
        whereConditions.add('estado = ?');
        whereArgs.add(estado);
      }

      if (activo != null) {
        whereConditions.add('activo = ?');
        whereArgs.add(activo ? 1 : 0);
      }

      final where = whereConditions.isEmpty
          ? ''
          : 'WHERE ' + whereConditions.join(' AND ');

      final rows = await db.rawQuery('''
        SELECT c.*, ep.nombre as entidad_nombre
        FROM compromisos c
        LEFT JOIN entidades_plantel ep ON ep.id = c.entidad_plantel_id
        $where
        ORDER BY c.fecha_inicio DESC, c.created_ts DESC
      ''', whereArgs.isEmpty ? null : whereArgs);

      return rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.listar',
        error: e,
        stackTrace: st,
        payload: {
          'unidadGestionId': unidadGestionId,
          'tipo': tipo,
          'estado': estado
        },
      );
      rethrow;
    }
  }

  /// FASE 31: Obtener compromisos con paginación
  ///
  /// [unidadGestionId] - ID de la unidad de gestión (obligatorio)
  /// [page] - Número de página (base 1, default: 1)
  /// [pageSize] - Items por página (default: 50)
  /// [entidadPlantelId] - Filtro opcional por jugador/DT
  /// [tipo] - Filtro opcional por tipo (INGRESO/EGRESO)
  /// [estado] - Filtro opcional por estado (ESPERADO/CONFIRMADO/CANCELADO)
  /// [activo] - Filtro opcional por estado activo
  /// [desde] - Fecha vencimiento desde (opcional)
  /// [hasta] - Fecha vencimiento hasta (opcional)
  Future<PaginatedResult<Map<String, dynamic>>> getCompromisosPaginados({
    required int unidadGestionId,
    int page = 1,
    int pageSize = 50,
    int? entidadPlantelId,
    String? tipo,
    String? estado,
    bool? activo,
    DateTime? desde,
    DateTime? hasta,
    bool incluirEliminados = false,
  }) async {
    try {
      final db = await AppDatabase.instance();

      // Construir WHERE clause
      final whereConditions = <String>[];
      final whereArgs = <dynamic>[];

      if (!incluirEliminados) {
        whereConditions.add('c.eliminado = 0');
      }

      whereConditions.add('c.unidad_gestion_id = ?');
      whereArgs.add(unidadGestionId);

      if (entidadPlantelId != null) {
        whereConditions.add('c.entidad_plantel_id = ?');
        whereArgs.add(entidadPlantelId);
      }

      if (tipo != null && tipo.isNotEmpty) {
        whereConditions.add('c.tipo = ?');
        whereArgs.add(tipo);
      }

      if (estado != null && estado.isNotEmpty) {
        whereConditions.add('c.estado = ?');
        whereArgs.add(estado);
      }

      if (activo != null) {
        whereConditions.add('c.activo = ?');
        whereArgs.add(activo ? 1 : 0);
      }

      if (desde != null) {
        whereConditions.add('c.fecha_vencimiento >= ?');
        whereArgs.add(desde.toIso8601String().substring(0, 10));
      }

      if (hasta != null) {
        whereConditions.add('c.fecha_vencimiento <= ?');
        whereArgs.add(hasta.toIso8601String().substring(0, 10));
      }

      final whereClause = whereConditions.join(' AND ');

      // Contar total de registros
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM compromisos c WHERE $whereClause',
        whereArgs,
      );
      final totalCount = Sqflite.firstIntValue(countResult) ?? 0;

      if (totalCount == 0) {
        return PaginatedResult.empty();
      }

      // Obtener items de la página actual con JOIN para nombre de entidad
      final offset = (page - 1) * pageSize;
      final query = '''
        SELECT 
          c.*,
          ep.nombre as entidad_nombre,
          ep.apellido as entidad_apellido,
          ep.tipo as entidad_tipo
        FROM compromisos c
        LEFT JOIN entidades_plantel ep ON c.entidad_plantel_id = ep.id
        WHERE $whereClause
        ORDER BY c.fecha_vencimiento ASC, c.created_ts DESC
        LIMIT ? OFFSET ?
      ''';

      final items = await db.rawQuery(
        query,
        [...whereArgs, pageSize, offset],
      );

      final compromisos =
          items.map((row) => Map<String, dynamic>.from(row)).toList();

      return PaginatedResult<Map<String, dynamic>>(
        items: compromisos,
        totalCount: totalCount,
        pageSize: pageSize,
        currentPage: page,
      );
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'compromisos_service.get_paginados',
        error: e.toString(),
        stackTrace: stack,
        payload: {
          'unidad_gestion_id': unidadGestionId,
          'page': page,
          'page_size': pageSize,
        },
      );
      return PaginatedResult.empty();
    }
  }

  /// Actualiza un compromiso existente.
  ///
  /// Solo actualiza los campos proporcionados (no nulls).
  /// Incrementa updated_ts y marca sync_estado como PENDIENTE.
  ///
  /// Retorna cantidad de filas actualizadas (0 o 1).
  Future<int> actualizarCompromiso(
    int id, {
    String? nombre,
    String? tipo,
    String? modalidad,
    double? monto,
    String? frecuencia,
    int? frecuenciaDias,
    int? cuotas,
    String? fechaInicio,
    String? fechaFin,
    String? categoria,
    String? observaciones,
    String? archivoLocalPath,
    String? archivoRemoteUrl,
    String? archivoNombre,
    String? archivoTipo,
    int? archivoSize,
    int? entidadPlantelId,
  }) async {
    try {
      final db = await AppDatabase.instance();

      // Verificar que existe y no está eliminado
      final existe = await obtenerCompromiso(id);
      if (existe == null) {
        throw ArgumentError('Compromiso no encontrado o eliminado');
      }

      // Validaciones
      if (monto != null && monto <= 0) {
        throw ArgumentError('El monto debe ser mayor a cero');
      }

      if (tipo != null && !['INGRESO', 'EGRESO'].contains(tipo)) {
        throw ArgumentError('Tipo inválido');
      }

      if (modalidad != null &&
          !['PAGO_UNICO', 'MONTO_TOTAL_CUOTAS', 'RECURRENTE']
              .contains(modalidad)) {
        throw ArgumentError('Modalidad inválida');
      }

      // Validar fechas
      final finalFechaInicio = fechaInicio ?? existe['fecha_inicio'] as String?;
      final finalFechaFin = fechaFin ?? existe['fecha_fin'] as String?;
      if (finalFechaInicio != null &&
          finalFechaFin != null &&
          finalFechaFin.compareTo(finalFechaInicio) < 0) {
        throw ArgumentError(
            'La fecha de fin debe ser posterior a la fecha de inicio');
      }

      // Validar frecuencia
      if (frecuencia != null) {
        final frec = await db.query(
          'frecuencias',
          where: 'codigo = ?',
          whereArgs: [frecuencia],
          limit: 1,
        );
        if (frec.isEmpty) {
          throw ArgumentError('Frecuencia inválida: $frecuencia');
        }
      }

      final updates = <String, dynamic>{
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        'sync_estado': 'PENDIENTE',
      };

      if (nombre != null) updates['nombre'] = nombre;
      if (tipo != null) updates['tipo'] = tipo;
      if (modalidad != null) updates['modalidad'] = modalidad;
      if (monto != null) updates['monto'] = monto;
      if (frecuencia != null) updates['frecuencia'] = frecuencia;
      if (frecuenciaDias != null) updates['frecuencia_dias'] = frecuenciaDias;
      if (cuotas != null) updates['cuotas'] = cuotas;
      if (fechaInicio != null) updates['fecha_inicio'] = fechaInicio;
      if (fechaFin != null) updates['fecha_fin'] = fechaFin;
      if (categoria != null) updates['categoria'] = categoria;
      if (observaciones != null) updates['observaciones'] = observaciones;
      if (archivoLocalPath != null)
        updates['archivo_local_path'] = archivoLocalPath;
      if (archivoRemoteUrl != null)
        updates['archivo_remote_url'] = archivoRemoteUrl;
      if (archivoNombre != null) updates['archivo_nombre'] = archivoNombre;
      if (archivoTipo != null) updates['archivo_tipo'] = archivoTipo;
      if (archivoSize != null) updates['archivo_size'] = archivoSize;
      if (entidadPlantelId != null)
        updates['entidad_plantel_id'] = entidadPlantelId;

      final result = await db.update(
        'compromisos',
        updates,
        where: 'id = ?',
        whereArgs: [id],
      );

      // FASE 22.1: Recalcular estado después de actualizar
      // Si se modificaron fechas, cuotas o modalidad, las cuotas pueden haber cambiado
      if (result > 0 &&
          (fechaInicio != null ||
              fechaFin != null ||
              cuotas != null ||
              modalidad != null)) {
        await recalcularEstado(id);
      }

      return result;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.actualizar',
        error: e,
        stackTrace: st,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Pausa un compromiso (activo=0).
  ///
  /// Los movimientos ESPERADOS futuros no se deben mostrar cuando está pausado.
  Future<int> pausarCompromiso(int id) async {
    try {
      final db = await AppDatabase.instance();
      return await db.update(
        'compromisos',
        {
          'activo': 0,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ? AND eliminado = 0',
        whereArgs: [id],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.pausar',
        error: e,
        stackTrace: st,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Reactiva un compromiso pausado (activo=1).
  Future<int> reactivarCompromiso(int id) async {
    try {
      final db = await AppDatabase.instance();
      return await db.update(
        'compromisos',
        {
          'activo': 1,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ? AND eliminado = 0',
        whereArgs: [id],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.reactivar',
        error: e,
        stackTrace: st,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Desactiva (soft delete) un compromiso (eliminado=1).
  ///
  /// Regla: NO se puede desactivar si tiene movimientos ESPERADOS pendientes.
  ///
  /// Lanza excepción si tiene movimientos ESPERADOS asociados.
  Future<int> desactivarCompromiso(int id) async {
    try {
      final db = await AppDatabase.instance();

      // Validar que no tenga movimientos ESPERADOS
      final esperados = await db.query(
        'evento_movimiento',
        where: 'compromiso_id = ? AND estado = ? AND eliminado = 0',
        whereArgs: [id, 'ESPERADO'],
        limit: 1,
      );

      if (esperados.isNotEmpty) {
        throw StateError(
            'No se puede desactivar el compromiso porque tiene movimientos esperados pendientes');
      }

      return await db.update(
        'compromisos',
        {
          'eliminado': 1,
          'activo': 0,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
          'sync_estado': 'PENDIENTE',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.desactivar',
        error: e,
        stackTrace: st,
        payload: {'id': id},
      );
      rethrow;
    }
  }

  /// Incrementa el contador de cuotas confirmadas.
  ///
  /// Se llama cuando se registra un movimiento CONFIRMADO asociado al compromiso.
  Future<int> incrementarCuotasConfirmadas(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();
      return await db.rawUpdate(
        'UPDATE compromisos SET cuotas_confirmadas = cuotas_confirmadas + 1, '
        'updated_ts = ?, sync_estado = ? '
        'WHERE id = ?',
        [DateTime.now().millisecondsSinceEpoch, 'PENDIENTE', compromisoId],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.incrementar_cuotas',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Cuenta cuotas confirmadas de un compromiso.
  ///
  /// Consulta la cantidad de movimientos CONFIRMADO asociados.
  Future<int> contarCuotasConfirmadas(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();
      final result = await db.rawQuery(
        'SELECT COUNT(*) as total FROM evento_movimiento '
        'WHERE compromiso_id = ? AND estado = ? AND eliminado = 0',
        [compromisoId, 'CONFIRMADO'],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.contar_cuotas',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Calcula cuotas restantes de un compromiso.
  ///
  /// FASE 22.1: Si hay cuotas generadas en compromiso_cuotas, cuenta las ESPERADO.
  /// Si NO hay cuotas generadas (legacy), usa cálculo basado en compromisos.cuotas.
  ///
  /// Retorna:
  /// - Si tiene cuotas definidas: cuotas - cuotas_confirmadas (legacy)
  /// - Si tiene cuotas generadas: count(estado = ESPERADO)
  /// - Si no tiene cuotas (null): null (infinitas)
  Future<int?> calcularCuotasRestantes(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();

      // Verificar si hay cuotas generadas en compromiso_cuotas
      final cuotasExistentes = await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id = ?',
        whereArgs: [compromisoId],
      );

      if (cuotasExistentes.isNotEmpty) {
        // Nuevo comportamiento: contar cuotas ESPERADO desde compromiso_cuotas
        final cuotasEsperadas = await db.query(
          'compromiso_cuotas',
          where: 'compromiso_id = ? AND estado = ?',
          whereArgs: [compromisoId, 'ESPERADO'],
        );
        return cuotasEsperadas.length;
      } else {
        // Legacy: calcular basado en compromisos.cuotas - confirmadas
        final comp = await obtenerCompromiso(compromisoId);
        if (comp == null) return null;

        final cuotasTotales = comp['cuotas'] as int?;
        if (cuotasTotales == null) return null;

        final confirmadas = await contarCuotasConfirmadas(compromisoId);
        return (cuotasTotales - confirmadas).clamp(0, cuotasTotales);
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.calcular_cuotas_restantes',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Calcula el próximo vencimiento de un compromiso.
  ///
  /// Algoritmo:
  /// 1. Obtener último movimiento CONFIRMADO del compromiso
  /// 2. Si no hay, partir de fecha_inicio
  /// 3. Sumar días según frecuencia
  /// 4. Si se excede fecha_fin o cuotas, retornar null
  ///
  /// Retorna null si:
  /// - El compromiso ya está completo (todas las cuotas confirmadas)
  /// - Se excedió la fecha_fin
  /// - El compromiso está pausado o eliminado
  Future<DateTime?> calcularProximoVencimiento(int compromisoId) async {
    try {
      final compromiso = await obtenerCompromiso(compromisoId);
      if (compromiso == null) return null;

      // Si está pausado, no hay próximo vencimiento
      if (compromiso['activo'] != 1) return null;

      final cuotasTotales = compromiso['cuotas'] as int?;
      final confirmadas = await contarCuotasConfirmadas(compromisoId);

      // Si ya se completaron todas las cuotas
      if (cuotasTotales != null && confirmadas >= cuotasTotales) {
        return null;
      }

      final db = await AppDatabase.instance();

      // Obtener último movimiento CONFIRMADO
      final ultimoMovimiento = await db.query(
        'evento_movimiento',
        where: 'compromiso_id = ? AND estado = ? AND eliminado = 0',
        whereArgs: [compromisoId, 'CONFIRMADO'],
        orderBy: 'created_ts DESC',
        limit: 1,
      );

      DateTime fechaBase;
      if (ultimoMovimiento.isNotEmpty) {
        // Partir desde el último movimiento
        final createdTs = ultimoMovimiento.first['created_ts'] as int;
        fechaBase = DateTime.fromMillisecondsSinceEpoch(createdTs);
      } else {
        // Partir desde fecha_inicio
        final fechaInicioStr = compromiso['fecha_inicio'] as String;
        fechaBase = DateTime.parse(fechaInicioStr);
      }

      // Obtener días de la frecuencia
      final frecuenciaCodigo = compromiso['frecuencia'] as String;
      int? diasASumar;

      final frecuenciaData = await db.query(
        'frecuencias',
        where: 'codigo = ?',
        whereArgs: [frecuenciaCodigo],
        limit: 1,
      );
      if (frecuenciaData.isNotEmpty) {
        diasASumar = frecuenciaData.first['dias'] as int?;
      }

      if (diasASumar == null || diasASumar <= 0) {
        // Frecuencia UNICA_VEZ: solo un vencimiento (en fecha_inicio)
        if (confirmadas > 0) return null;
        return DateTime.parse(compromiso['fecha_inicio'] as String);
      }

      // Calcular próximo vencimiento
      final proximoVencimiento = fechaBase.add(Duration(days: diasASumar));

      // Validar contra fecha_fin
      final fechaFinStr = compromiso['fecha_fin'] as String?;
      if (fechaFinStr != null) {
        final fechaFin = DateTime.parse(fechaFinStr);
        if (proximoVencimiento.isAfter(fechaFin)) {
          return null; // Ya se excedió la fecha límite
        }
      }

      return proximoVencimiento;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.calcular_proximo_vencimiento',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Obtiene compromisos activos con próximo vencimiento en el rango de fechas.
  ///
  /// Útil para mostrar vencimientos del mes.
  Future<List<Map<String, dynamic>>> listarVencimientosEnRango({
    required DateTime desde,
    required DateTime hasta,
    int? unidadGestionId,
  }) async {
    try {
      final compromisos = await listarCompromisos(
        unidadGestionId: unidadGestionId,
        activo: true,
      );

      final vencimientos = <Map<String, dynamic>>[];

      for (final compromiso in compromisos) {
        final id = compromiso['id'] as int;
        final proximoVencimiento = await calcularProximoVencimiento(id);

        if (proximoVencimiento != null &&
            !proximoVencimiento.isBefore(desde) &&
            !proximoVencimiento.isAfter(hasta)) {
          vencimientos.add({
            ...compromiso,
            'proximo_vencimiento': proximoVencimiento.toIso8601String(),
          });
        }
      }

      // Ordenar por fecha de vencimiento
      vencimientos.sort((a, b) {
        final fechaA = DateTime.parse(a['proximo_vencimiento'] as String);
        final fechaB = DateTime.parse(b['proximo_vencimiento'] as String);
        return fechaA.compareTo(fechaB);
      });

      return vencimientos;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.listar_vencimientos',
        error: e,
        stackTrace: st,
        payload: {
          'desde': desde.toIso8601String(),
          'hasta': hasta.toIso8601String(),
          'unidadGestionId': unidadGestionId
        },
      );
      rethrow;
    }
  }

  /// Sincroniza el contador de cuotas_confirmadas desde la base de datos.
  ///
  /// Útil para corregir inconsistencias.
  Future<int> sincronizarCuotasConfirmadas(int compromisoId) async {
    try {
      final confirmadas = await contarCuotasConfirmadas(compromisoId);
      final db = await AppDatabase.instance();
      return await db.update(
        'compromisos',
        {
          'cuotas_confirmadas': confirmadas,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [compromisoId],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.sincronizar_cuotas',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  // ===================================================================
  // FASE 13.5: Gestión de cuotas de compromisos
  // ===================================================================

  /// Genera cuotas automáticamente según la modalidad del compromiso.
  ///
  /// Modalidades:
  /// - PAGO_UNICO: genera 1 sola cuota en fecha_inicio
  /// - MONTO_TOTAL_CUOTAS: divide monto total en N cuotas con distribución automática
  /// - RECURRENTE: genera cuotas con monto fijo por período (limitado al año actual)
  ///
  /// Parámetros:
  /// - [compromisoId]: ID del compromiso
  /// - [montosPersonalizados]: lista opcional de montos por cuota (solo para MONTO_TOTAL_CUOTAS)
  ///
  /// Retorna lista de mapas con estructura de cuota (sin insertar en DB).
  Future<List<Map<String, dynamic>>> generarCuotas(
    int compromisoId, {
    List<double>? montosPersonalizados,
    List<String>? fechasPersonalizadas,
  }) async {
    try {
      final compromiso = await obtenerCompromiso(compromisoId);
      if (compromiso == null) {
        throw ArgumentError('Compromiso no encontrado');
      }

      final modalidad = compromiso.safeString('modalidad', 'RECURRENTE');
      final monto = compromiso.safeDouble('monto');
      final fechaInicioStr = compromiso.safeString('fecha_inicio');
      final fechaInicio = DateTime.parse(fechaInicioStr);
      final fechaFinStr = compromiso.safeStringOrNull('fecha_fin');
      final frecuencia = compromiso.safeString('frecuencia');
      final frecuenciaDias = compromiso.safeIntOrNull('frecuencia_dias');

      final cuotas = <Map<String, dynamic>>[];
      final now = DateTime.now();
      final finDeAnioActual = DateTime(now.year, 12, 31, 23, 59, 59);

      switch (modalidad) {
        case 'PAGO_UNICO':
          // Una sola cuota en fecha_inicio
          cuotas.add({
            'numero_cuota': 1,
            'fecha_programada': fechaInicioStr,
            'monto_esperado': monto,
            'estado': 'ESPERADO',
          });
          break;

        case 'MONTO_TOTAL_CUOTAS':
          // Dividir monto total en cuotas
          final cantidadCuotas = compromiso.safeInt('cuotas', 1);
          if (cantidadCuotas <= 0) {
            throw ArgumentError('Cantidad de cuotas debe ser mayor a 0');
          }

          // Validar montos personalizados
          if (montosPersonalizados != null) {
            if (montosPersonalizados.length != cantidadCuotas) {
              throw ArgumentError(
                  'La cantidad de montos personalizados debe coincidir con la cantidad de cuotas');
            }
            final sumaMontos = montosPersonalizados.reduce((a, b) => a + b);
            if ((sumaMontos - monto).abs() > 0.01) {
              throw ArgumentError(
                  'La suma de montos personalizados (\$$sumaMontos) no coincide con el monto total (\$$monto)');
            }
          }

          // Validar fechas personalizadas
          if (fechasPersonalizadas != null) {
            if (fechasPersonalizadas.length != cantidadCuotas) {
              throw ArgumentError(
                  'La cantidad de fechas personalizadas debe coincidir con la cantidad de cuotas');
            }
          }

          // Calcular monto por cuota (distribución automática)
          final montoPorCuota = monto / cantidadCuotas;

          for (int i = 0; i < cantidadCuotas; i++) {
            String fechaProgramada;

            if (fechasPersonalizadas != null &&
                i < fechasPersonalizadas.length) {
              // Usar fecha personalizada
              fechaProgramada = fechasPersonalizadas[i];
            } else {
              // Calcular fecha automáticamente
              final fechaCuota = _calcularProximaFecha(
                fechaInicio,
                frecuencia,
                frecuenciaDias,
                i,
              );
              fechaProgramada = fechaCuota.toIso8601String().split('T')[0];
            }

            final montoFinal = montosPersonalizados != null
                ? montosPersonalizados[i]
                : montoPorCuota;

            cuotas.add({
              'numero_cuota': i + 1,
              'fecha_programada': fechaProgramada,
              'monto_esperado': montoFinal,
              'estado': 'ESPERADO',
            });
          }
          break;

        case 'RECURRENTE':
          // Monto fijo por período
          DateTime? fechaFin;
          if (fechaFinStr != null) {
            fechaFin = DateTime.parse(fechaFinStr);
          }

          // Generar cuotas hasta fecha_fin o fin del año actual (lo que sea antes)
          // Si no hay fecha_fin, generar hasta fin del año actual
          DateTime fechaLimite = finDeAnioActual;
          if (fechaFin != null && fechaFin.isBefore(finDeAnioActual)) {
            fechaLimite = fechaFin;
          }

          int numeroCuota = 1;
          DateTime fechaCuota = fechaInicio;

          // Generar cuotas mientras la fecha no supere el límite
          while (fechaCuota.isBefore(fechaLimite) ||
              fechaCuota.isAtSameMomentAs(fechaLimite)) {
            cuotas.add({
              'numero_cuota': numeroCuota,
              'fecha_programada': fechaCuota.toIso8601String().split('T')[0],
              'monto_esperado': monto,
              'estado': 'ESPERADO',
            });

            fechaCuota = _calcularProximaFecha(
              fechaInicio,
              frecuencia,
              frecuenciaDias,
              numeroCuota,
            );
            numeroCuota++;

            // Evitar bucle infinito
            if (numeroCuota > 1000) {
              break;
            }
          }
          break;

        default:
          throw ArgumentError('Modalidad inválida: $modalidad');
      }

      return cuotas;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.generar_cuotas',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Calcula la próxima fecha según la frecuencia.
  ///
  /// Para frecuencia MENSUAL: suma meses correctamente (evita problema de 30 días)
  /// Para otras frecuencias: suma días según la tabla frecuencias
  ///
  /// [fechaBase]: fecha de inicio
  /// [frecuencia]: código de frecuencia (MENSUAL, SEMANAL, etc.)
  /// [frecuenciaDias]: días de frecuencia personalizada (si aplica)
  /// [iteracion]: número de iteración (0 para la primera, 1 para la segunda, etc.)
  DateTime _calcularProximaFecha(
    DateTime fechaBase,
    String frecuencia,
    int? frecuenciaDias,
    int iteracion,
  ) {
    // Si es la primera iteración, retornar la fecha base
    if (iteracion == 0) {
      return fechaBase;
    }

    // Para frecuencia MENSUAL, sumar meses correctamente
    if (frecuencia == 'MENSUAL') {
      return DateTime(
        fechaBase.year,
        fechaBase.month + iteracion,
        fechaBase.day,
        fechaBase.hour,
        fechaBase.minute,
        fechaBase.second,
      );
    }

    // Para otras frecuencias, calcular días y sumar
    int dias = 0;

    switch (frecuencia) {
      case 'DIARIA':
        dias = 1;
        break;
      case 'SEMANAL':
        dias = 7;
        break;
      case 'QUINCENAL':
        dias = 15;
        break;
      case 'BIMESTRAL':
        // 2 meses, aproximadamente
        return DateTime(
          fechaBase.year,
          fechaBase.month + (iteracion * 2),
          fechaBase.day,
        );
      case 'TRIMESTRAL':
        // 3 meses
        return DateTime(
          fechaBase.year,
          fechaBase.month + (iteracion * 3),
          fechaBase.day,
        );
      case 'CUATRIMESTRAL':
        // 4 meses
        return DateTime(
          fechaBase.year,
          fechaBase.month + (iteracion * 4),
          fechaBase.day,
        );
      case 'SEMESTRAL':
        // 6 meses
        return DateTime(
          fechaBase.year,
          fechaBase.month + (iteracion * 6),
          fechaBase.day,
        );
      case 'ANUAL':
        return DateTime(
          fechaBase.year + iteracion,
          fechaBase.month,
          fechaBase.day,
        );
      default:
        dias = 30; // Default mensual
    }

    return fechaBase.add(Duration(days: dias * iteracion));
  }

  /// Guarda cuotas en la base de datos.
  ///
  /// Elimina cuotas existentes del compromiso y guarda las nuevas.
  Future<void> guardarCuotas(
    int compromisoId,
    List<Map<String, dynamic>> cuotas,
  ) async {
    try {
      final db = await AppDatabase.instance();
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.transaction((txn) async {
        // Eliminar cuotas existentes
        await txn.delete(
          'compromiso_cuotas',
          where: 'compromiso_id = ?',
          whereArgs: [compromisoId],
        );

        // Insertar nuevas cuotas
        for (final cuota in cuotas) {
          await txn.insert('compromiso_cuotas', {
            'compromiso_id': compromisoId,
            'numero_cuota': cuota['numero_cuota'],
            'fecha_programada': cuota['fecha_programada'],
            'monto_esperado': cuota['monto_esperado'],
            'estado': cuota['estado'] ?? 'ESPERADO',
            'monto_real': cuota['monto_real'],
            'created_ts': now,
            'updated_ts': now,
          });
        }
      });
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.guardar_cuotas',
        error: e,
        stackTrace: st,
        payload: {
          'compromisoId': compromisoId,
          'cantidadCuotas': cuotas.length
        },
      );
      rethrow;
    }
  }

  /// Obtiene cuotas de un compromiso.
  ///
  /// Retorna lista ordenada por numero_cuota.
  Future<List<Map<String, dynamic>>> obtenerCuotas(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();
      return await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id = ?',
        whereArgs: [compromisoId],
        orderBy: 'numero_cuota ASC',
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.obtener_cuotas',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Actualiza el estado de una cuota.
  Future<int> actualizarEstadoCuota(
    int cuotaId,
    String nuevoEstado, {
    double? montoReal,
  }) async {
    try {
      if (!['ESPERADO', 'CONFIRMADO', 'CANCELADO'].contains(nuevoEstado)) {
        throw ArgumentError('Estado inválido: $nuevoEstado');
      }

      final db = await AppDatabase.instance();
      final updates = <String, dynamic>{
        'estado': nuevoEstado,
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
      };

      if (montoReal != null) {
        updates['monto_real'] = montoReal;
      }

      return await db.update(
        'compromiso_cuotas',
        updates,
        where: 'id = ?',
        whereArgs: [cuotaId],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.actualizar_cuota',
        error: e,
        stackTrace: st,
        payload: {'cuotaId': cuotaId, 'nuevoEstado': nuevoEstado},
      );
      rethrow;
    }
  }

  /// Valida que la suma de montos personalizados coincida con el monto total.
  bool validarSumaMontos(List<double> montos, double montoTotal) {
    final suma = montos.reduce((a, b) => a + b);
    return (suma - montoTotal).abs() <= 0.01; // Tolerancia de 1 centavo
  }

  /// Calcula el monto total pagado de un compromiso (suma de cuotas CONFIRMADAS).
  ///
  /// Retorna la suma del monto_real de todas las cuotas confirmadas.
  /// Si una cuota confirmada no tiene monto_real, usa monto_esperado.
  Future<double> calcularMontoPagado(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();
      final rows = await db.query(
        'compromiso_cuotas',
        columns: ['monto_real', 'monto_esperado'],
        where: 'compromiso_id = ? AND estado = ?',
        whereArgs: [compromisoId, 'CONFIRMADO'],
      );

      double total = 0.0;
      for (final row in rows) {
        final montoReal = (row['monto_real'] as num?)?.toDouble();
        final montoEsperado =
            (row['monto_esperado'] as num?)?.toDouble() ?? 0.0;
        total += (montoReal ?? montoEsperado);
      }

      return total;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.calcular_pagado',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// Calcula el monto remanente de un compromiso.
  ///
  /// Para PAGO_UNICO y MONTO_TOTAL_CUOTAS: monto total - monto pagado
  /// Para RECURRENTE: suma de monto_esperado de cuotas ESPERADAS
  Future<double> calcularMontoRemanente(int compromisoId) async {
    try {
      final compromiso = await obtenerCompromiso(compromisoId);
      if (compromiso == null) return 0.0;

      final modalidad = compromiso['modalidad'] as String?;
      final montoTotal = (compromiso['monto'] as num?)?.toDouble() ?? 0.0;

      if (modalidad == 'RECURRENTE') {
        // Para recurrente, sumar cuotas esperadas
        final db = await AppDatabase.instance();
        final rows = await db.query(
          'compromiso_cuotas',
          columns: ['monto_esperado'],
          where: 'compromiso_id = ? AND estado = ?',
          whereArgs: [compromisoId, 'ESPERADO'],
        );

        double total = 0.0;
        for (final row in rows) {
          total += (row['monto_esperado'] as num?)?.toDouble() ?? 0.0;
        }
        return total;
      } else {
        // Para pago único y monto total en cuotas
        final pagado = await calcularMontoPagado(compromisoId);
        return montoTotal - pagado;
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.calcular_remanente',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// FASE 18: Listar compromisos vinculados a un acuerdo
  ///
  /// Retorna todos los compromisos generados desde un acuerdo específico.
  Future<List<Map<String, dynamic>>> listarCompromisosPorAcuerdo(
      int acuerdoId) async {
    try {
      final db = await AppDatabase.instance();
      final rows = await db.query(
        'compromisos',
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [acuerdoId],
        orderBy: 'fecha_inicio ASC, created_ts ASC',
      );
      return rows;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.listar_por_acuerdo',
        error: e,
        stackTrace: st,
        payload: {'acuerdoId': acuerdoId},
      );
      rethrow;
    }
  }

  /// FASE 18: Verificar si un compromiso fue generado por un acuerdo
  ///
  /// Retorna true si el compromiso tiene acuerdo_id != null
  Future<bool> esCompromisoPorAcuerdo(int compromisoId) async {
    try {
      final compromiso = await obtenerCompromiso(compromisoId);
      if (compromiso == null) return false;
      return compromiso['acuerdo_id'] != null;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.es_por_acuerdo',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// FASE 18: Obtener información del acuerdo de origen de un compromiso
  ///
  /// Retorna el acuerdo que generó este compromiso, o null si no existe o el compromiso es manual
  Future<Map<String, dynamic>?> obtenerAcuerdoOrigen(int compromisoId) async {
    try {
      final compromiso = await obtenerCompromiso(compromisoId);
      if (compromiso == null || compromiso['acuerdo_id'] == null) {
        return null;
      }

      final acuerdoId = compromiso['acuerdo_id'] as int;
      final db = await AppDatabase.instance();
      final rows = await db.query(
        'acuerdos',
        where: 'id = ? AND eliminado = 0',
        whereArgs: [acuerdoId],
        limit: 1,
      );

      return rows.isEmpty ? null : rows.first;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.obtener_acuerdo_origen',
        error: e,
        stackTrace: st,
        payload: {'compromisoId': compromisoId},
      );
      rethrow;
    }
  }

  /// FASE 22.1: Recalcular cuotas_totales y cuotas_confirmadas desde la base de datos
  ///
  /// Este método cuenta las cuotas reales generadas en la tabla compromiso_cuotas
  /// y actualiza los campos correspondientes en la tabla compromisos.
  ///
  /// Se debe llamar después de:
  /// - Modificar un compromiso (cambio de fechas, cuotas, etc.)
  /// - Generar nuevas cuotas
  /// - Eliminar cuotas
  /// - Confirmar un movimiento de cuota
  ///
  /// Retorna: mapa con 'cuotas_totales' y 'cuotas_confirmadas'
  Future<Map<String, int>> recalcularEstado(int compromisoId) async {
    try {
      final db = await AppDatabase.instance();

      // Contar cuotas totales generadas en compromiso_cuotas
      final totalResult = await db.rawQuery('''
        SELECT COUNT(*) as total
        FROM compromiso_cuotas
        WHERE compromiso_id = ?
      ''', [compromisoId]);

      final cuotasTotales = (totalResult.first.safeInt('total'));

      // Contar cuotas confirmadas
      final confirmadasResult = await db.rawQuery('''
        SELECT COUNT(*) as confirmadas
        FROM compromiso_cuotas
        WHERE compromiso_id = ? AND estado = 'CONFIRMADO'
      ''', [compromisoId]);

      final cuotasConfirmadas =
          (confirmadasResult.first.safeInt('confirmadas'));

      // Actualizar compromiso con los valores recalculados
      await db.update(
        'compromisos',
        {
          'cuotas': cuotasTotales,
          'cuotas_confirmadas': cuotasConfirmadas,
          'updated_ts': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [compromisoId],
      );

      return {
        'cuotas_totales': cuotasTotales,
        'cuotas_confirmadas': cuotasConfirmadas,
      };
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'compromisos_service.recalcular_estado',
        error: e.toString(),
        stackTrace: stack,
        payload: {'compromiso_id': compromisoId},
      );
      rethrow;
    }
  }

  /// Cuenta las cuotas vencidas (fecha_programada < hoy, estado ESPERADO, compromiso activo).
  ///
  /// Útil para mostrar badge de alerta en la pantalla de Tesorería.
  Future<int> contarVencidos({required int unidadGestionId}) async {
    try {
      final db = await AppDatabase.instance();
      final hoy = DateTime.now().toIso8601String().substring(0, 10);
      final result = await db.rawQuery(
        '''SELECT COUNT(*) as total
           FROM compromiso_cuotas cc
           INNER JOIN compromisos c ON c.id = cc.compromiso_id
           WHERE cc.estado = 'ESPERADO'
             AND cc.fecha_programada < ?
             AND c.activo = 1
             AND c.eliminado = 0
             AND c.unidad_gestion_id = ?''',
        [hoy, unidadGestionId],
      );
      return (result.first.safeInt('total'));
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'compromisos_service.contar_vencidos',
        error: e.toString(),
        stackTrace: stack,
        payload: {'unidad_gestion_id': unidadGestionId},
      );
      return 0;
    }
  }

  /// Cuenta las cuotas próximas a vencer (dentro de los próximos N días).
  Future<int> contarProximosAVencer({
    required int unidadGestionId,
    int diasLimite = 7,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final hoy = DateTime.now().toIso8601String().substring(0, 10);
      final limite = DateTime.now()
          .add(Duration(days: diasLimite))
          .toIso8601String()
          .substring(0, 10);
      final result = await db.rawQuery(
        '''SELECT COUNT(*) as total
           FROM compromiso_cuotas cc
           INNER JOIN compromisos c ON c.id = cc.compromiso_id
           WHERE cc.estado = 'ESPERADO'
             AND cc.fecha_programada >= ?
             AND cc.fecha_programada <= ?
             AND c.activo = 1
             AND c.eliminado = 0
             AND c.unidad_gestion_id = ?''',
        [hoy, limite, unidadGestionId],
      );
      return (result.first.safeInt('total'));
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'compromisos_service.contar_proximos_vencer',
        error: e.toString(),
        stackTrace: stack,
        payload: {'unidad_gestion_id': unidadGestionId, 'dias': diasLimite},
      );
      return 0;
    }
  }

  /// Obtiene cuotas agrupadas por fecha y estado para el calendario de pagos.
  ///
  /// Retorna lista de cuotas con información del compromiso asociado,
  /// ordenadas por fecha_programada ASC.
  ///
  /// Parámetros:
  /// - [unidadGestionId]: filtrar por unidad de gestión (opcional)
  /// - [desde]: fecha inicio del rango (YYYY-MM-DD). Default: 30 días atrás.
  /// - [hasta]: fecha fin del rango (YYYY-MM-DD). Default: 60 días adelante.
  /// - [soloEsperado]: si es true, solo cuotas ESPERADO; si false, todas.
  ///
  /// Cada registro incluye:
  /// - id, compromiso_id, numero_cuota, fecha_programada, monto_esperado, estado
  /// - compromiso_nombre, compromiso_tipo, entidad_nombre
  Future<List<Map<String, dynamic>>> obtenerCuotasParaCalendario({
    int? unidadGestionId,
    String? desde,
    String? hasta,
    bool soloEsperado = false,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final hoy = DateTime.now();
      final desdeStr = desde ??
          hoy
              .subtract(const Duration(days: 30))
              .toIso8601String()
              .substring(0, 10);
      final hastaStr = hasta ??
          hoy.add(const Duration(days: 60)).toIso8601String().substring(0, 10);

      final conditions = <String>[
        'cc.fecha_programada >= ?',
        'cc.fecha_programada <= ?',
        'c.activo = 1',
        'c.eliminado = 0',
      ];
      final args = <dynamic>[desdeStr, hastaStr];

      if (soloEsperado) {
        conditions.add("cc.estado = 'ESPERADO'");
      }

      if (unidadGestionId != null) {
        conditions.add('c.unidad_gestion_id = ?');
        args.add(unidadGestionId);
      }

      final whereClause = conditions.join(' AND ');

      final results = await db.rawQuery('''
        SELECT
          cc.id,
          cc.compromiso_id,
          cc.numero_cuota,
          cc.fecha_programada,
          cc.monto_esperado,
          cc.monto_real,
          cc.estado AS cuota_estado,
          c.nombre AS compromiso_nombre,
          c.tipo AS compromiso_tipo,
          c.modalidad,
          c.acuerdo_id,
          ep.nombre AS entidad_nombre
        FROM compromiso_cuotas cc
        INNER JOIN compromisos c ON c.id = cc.compromiso_id
        LEFT JOIN entidades_plantel ep ON ep.id = c.entidad_plantel_id
        WHERE $whereClause
        ORDER BY cc.fecha_programada ASC, c.nombre ASC
      ''', args);

      return results.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos_service.cuotas_calendario',
        error: e.toString(),
        stackTrace: st,
        payload: {'desde': desde, 'hasta': hasta},
      );
      return [];
    }
  }

  /// H.6: Confirma una cuota de compromiso de forma transaccional.
  ///
  /// Dentro de una única transacción:
  /// 1. Inserta movimiento en `evento_movimiento` con estado CONFIRMADO.
  /// 2. Actualiza la cuota en `compromiso_cuotas` a CONFIRMADO (si existe).
  /// 3. Incrementa `cuotas_confirmadas` en `compromisos`.
  ///
  /// Si cualquier paso falla, toda la operación se revierte.
  Future<int> confirmarCuota({
    required int compromisoId,
    required int disciplinaId,
    required int cuentaId,
    required String tipo,
    required String categoria,
    required double monto,
    required int medioPagoId,
    required DateTime fechaReal,
    required DateTime fechaVencimiento,
    required int numeroCuota,
    int? unidadGestionId,
    String? observacion,
    String? archivoLocalPath,
    String? archivoNombre,
    String? archivoTipo,
    // Campos para acuerdos en litros (unidad = 'LTS')
    double? cantidadLitros,
    double? precioLitroArs,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final fechaStr =
          '${fechaReal.year}-${fechaReal.month.toString().padLeft(2, '0')}-${fechaReal.day.toString().padLeft(2, '0')}';

      return await db.transaction((txn) async {
        // 1) Insertar movimiento confirmado
        final movId = await txn.insert('evento_movimiento', {
          'disciplina_id': disciplinaId,
          'unidad_gestion_id': unidadGestionId ?? disciplinaId,
          'cuenta_id': cuentaId,
          'tipo': tipo.toUpperCase(),
          'categoria': categoria,
          'monto': monto,
          'medio_pago_id': medioPagoId,
          'fecha': fechaStr,
          'observacion': observacion,
          'compromiso_id': compromisoId,
          'estado': 'CONFIRMADO',
          'archivo_local_path': archivoLocalPath,
          'archivo_nombre': archivoNombre,
          'archivo_tipo': archivoTipo,
          'created_ts': now,
          'sync_estado': 'PENDIENTE',
          'eliminado': 0,
          'es_transferencia': 0,
        });

        // 2) Marcar cuota como CONFIRMADO (por numero_cuota si es válido, o por mes/año)
        final anioMes =
            '${fechaVencimiento.year.toString().padLeft(4, '0')}-'
            '${fechaVencimiento.month.toString().padLeft(2, '0')}';
        final updated = await txn.rawUpdate(
          '''UPDATE compromiso_cuotas
             SET estado = 'CONFIRMADO',
                 monto_real = ?,
                 cantidad_litros = ?,
                 precio_litro_ars = ?,
                 updated_ts = ?
             WHERE compromiso_id = ?
               AND estado != 'CONFIRMADO'
               AND (numero_cuota = ? AND ? > 0
                    OR strftime('%Y-%m', fecha_programada) = ?)''',
          [monto, cantidadLitros, precioLitroArs, now, compromisoId, numeroCuota, numeroCuota, anioMes],
        );
        // Si no hubo coincidencia intentar solo por mes (para cuotas creadas sin numero)
        if (updated == 0) {
          await txn.rawUpdate(
            '''UPDATE compromiso_cuotas
               SET estado = 'CONFIRMADO',
                   monto_real = ?,
                   cantidad_litros = ?,
                   precio_litro_ars = ?,
                   updated_ts = ?
               WHERE compromiso_id = ?
                 AND estado != 'CONFIRMADO'
                 AND strftime('%Y-%m', fecha_programada) = ?''',
            [monto, cantidadLitros, precioLitroArs, now, compromisoId, anioMes],
          );
        }

        // 3) Incrementar contador de cuotas confirmadas en el compromiso
        await txn.rawUpdate(
          '''UPDATE compromisos
             SET cuotas_confirmadas = cuotas_confirmadas + 1,
                 updated_ts = ?,
                 sync_estado = 'PENDIENTE'
             WHERE id = ?''',
          [now, compromisoId],
        );

        return movId;
      });
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'compromisos.confirmar_cuota',
        error: e.toString(),
        stackTrace: st,
        payload: {
          'compromisoId': compromisoId,
          'numeroCuota': numeroCuota,
          'monto': monto,
          'disciplinaId': disciplinaId,
        },
      );
      rethrow;
    }
  }
}
