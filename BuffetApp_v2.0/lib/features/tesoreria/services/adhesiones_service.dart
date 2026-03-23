import 'package:sqflite/sqflite.dart';
import '../../../data/dao/db.dart';

/// Servicio para la pantalla de Adhesiones (vista pivot de acuerdos + cuotas).
///
/// "Adhesiones" son acuerdos de tipo INGRESO con categoría COLA (Sueldos)
/// o COMB (Combustible), que representan aportes de adherentes al club.
///
/// Este servicio NO crea tablas nuevas — es una vista pivot sobre:
/// - acuerdos (adherente = acuerdo de tipo INGRESO)
/// - compromisos (vínculo acuerdo → cuotas)
/// - compromiso_cuotas (pagos mensuales)
class AdhesionesService {
  AdhesionesService._();
  static final instance = AdhesionesService._();

  /// Obtiene la lista de adherentes con sus pagos mensuales para un año.
  ///
  /// [anio]: Año a consultar (ej: 2025)
  /// [categoriaGrupo]: 'SUELDOS' o 'COMBUSTIBLE' → mapea a categorías COLA o COMB
  /// [unidadGestionId]: Opcional, filtra por subcomisión
  ///
  /// Retorna lista de mapas con estructura:
  /// ```
  /// {
  ///   'acuerdo_id': int,
  ///   'nombre': String,          // nombre del acuerdo (adherente)
  ///   'entidad_nombre': String,  // entidad plantel vinculada
  ///   'monto_periodico': double, // monto mensual esperado
  ///   'unidad': 'ARS' | 'LTS',
  ///   'activo': int,
  ///   'cuotas': { 1: {...}, 2: {...}, ... 12: {...} }  // mes → cuota info
  /// }
  /// ```
  Future<List<Map<String, dynamic>>> obtenerAdherentesConPagos({
    required int anio,
    required String categoriaGrupo,
    int? unidadGestionId,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final categoria = categoriaGrupo == 'COMBUSTIBLE' ? 'COMB' : 'COLA';

      // 1. Obtener acuerdos de la categoría
      final whereClause = StringBuffer(
        "a.categoria = ? AND a.tipo = 'INGRESO' AND a.eliminado = 0"
      );
      final whereArgs = <dynamic>[categoria];

      if (unidadGestionId != null) {
        whereClause.write(' AND a.unidad_gestion_id = ?');
        whereArgs.add(unidadGestionId);
      }

      final acuerdos = await db.rawQuery('''
        SELECT
          a.id AS acuerdo_id,
          a.nombre,
          a.monto_periodico,
          a.monto_total,
          a.modalidad,
          a.cuotas,
          a.unidad,
          a.activo,
          a.tipo,
          a.categoria,
          ep.nombre AS entidad_nombre
        FROM acuerdos a
        LEFT JOIN entidades_plantel ep ON ep.id = a.entidad_plantel_id
        WHERE $whereClause
        ORDER BY a.nombre ASC
      ''', whereArgs);

      if (acuerdos.isEmpty) return [];

      // 2. Obtener todas las cuotas del año para estos acuerdos
      final acuerdoIds = acuerdos.map((a) => a['acuerdo_id']).toList();
      final placeholders = acuerdoIds.map((_) => '?').join(',');

      final fechaDesde = '$anio-01-01';
      final fechaHasta = '$anio-12-31';

      final cuotas = await db.rawQuery('''
        SELECT
          c.acuerdo_id,
          cc.numero_cuota,
          cc.fecha_programada,
          cc.monto_esperado,
          cc.monto_real,
          cc.estado,
          cc.id AS cuota_id,
          cc.compromiso_id
        FROM compromiso_cuotas cc
        INNER JOIN compromisos c ON c.id = cc.compromiso_id
        WHERE c.acuerdo_id IN ($placeholders)
          AND cc.fecha_programada >= ?
          AND cc.fecha_programada <= ?
          AND c.eliminado = 0
        ORDER BY cc.fecha_programada ASC
      ''', [...acuerdoIds, fechaDesde, fechaHasta]);

      // 3. Agrupar cuotas por acuerdo y mes
      final cuotasPorAcuerdo = <int, Map<int, Map<String, dynamic>>>{};
      for (final cuota in cuotas) {
        final acuerdoId = cuota['acuerdo_id'] as int;
        final fechaStr = cuota['fecha_programada'] as String;
        final mes = DateTime.parse(fechaStr).month;

        cuotasPorAcuerdo.putIfAbsent(acuerdoId, () => {});
        cuotasPorAcuerdo[acuerdoId]![mes] = {
          'cuota_id': cuota['cuota_id'],
          'compromiso_id': cuota['compromiso_id'],
          'estado': cuota['estado'],
          'monto_esperado': (cuota['monto_esperado'] as num?)?.toDouble() ?? 0.0,
          'monto_real': (cuota['monto_real'] as num?)?.toDouble(),
          'fecha_programada': fechaStr,
        };
      }

      // 4. Armar resultado con pivot
      return acuerdos.map((a) {
        final acuerdoId = a['acuerdo_id'] as int;
        final montoPeriodico = (a['monto_periodico'] as num?)?.toDouble() ?? 0.0;

        return {
          'acuerdo_id': acuerdoId,
          'nombre': a['nombre']?.toString() ?? 'Sin nombre',
          'entidad_nombre': a['entidad_nombre']?.toString() ?? '—',
          'monto_periodico': montoPeriodico,
          'unidad': a['unidad']?.toString() ?? 'ARS',
          'activo': a['activo'] ?? 1,
          'tipo': a['tipo']?.toString() ?? 'INGRESO',
          'categoria': a['categoria']?.toString() ?? '',
          'cuotas': cuotasPorAcuerdo[acuerdoId] ?? <int, Map<String, dynamic>>{},
        };
      }).toList();
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_service.obtener_adherentes',
        error: e.toString(),
        stackTrace: stack,
        payload: {'anio': anio, 'categoriaGrupo': categoriaGrupo},
      );
      return [];
    }
  }

  /// Calcula KPIs agregados para un tab de adhesiones.
  ///
  /// Retorna:
  /// ```
  /// {
  ///   'prometido_anual': double,
  ///   'cobrado': double,
  ///   'resta_cobrar': double,
  ///   'porcentaje_al_dia': double,
  ///   'total_adherentes': int,
  ///   'con_deuda': int,
  ///   'al_dia': int,
  ///   'sin_cuota': int,
  /// }
  /// ```
  Map<String, dynamic> calcularKPIs({
    required List<Map<String, dynamic>> adherentes,
    required int anio,
  }) {
    double prometidoAnual = 0;
    double cobrado = 0;
    int conDeuda = 0;
    int alDia = 0;
    int sinCuota = 0;
    final ahora = DateTime.now();
    final mesActual = ahora.year == anio ? ahora.month : 12;

    for (final adherente in adherentes) {
      final montoPeriodico = (adherente['monto_periodico'] as num?)?.toDouble() ?? 0.0;
      final cuotasMap = adherente['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
      final esCancelado = (adherente['activo'] as int? ?? 1) == 0;

      // Los cancelados no aportan al prometido anual (ya no van a pagar)
      if (!esCancelado) prometidoAnual += montoPeriodico * 12;

      // Cobrado = suma de monto_real de cuotas CONFIRMADAS (incluye cancelados)
      double cobradoAdherente = 0;
      bool tieneDeuda = false;
      bool tieneCuotas = cuotasMap.isNotEmpty;

      for (int mes = 1; mes <= 12; mes++) {
        final cuota = cuotasMap[mes];
        if (cuota != null) {
          if (cuota['estado'] == 'CONFIRMADO') {
            cobradoAdherente += (cuota['monto_real'] as num?)?.toDouble()
                ?? (cuota['monto_esperado'] as num?)?.toDouble()
                ?? 0.0;
          } else if (!esCancelado && mes <= mesActual && cuota['estado'] == 'ESPERADO') {
            tieneDeuda = true;
          }
        } else if (!esCancelado && mes <= mesActual && montoPeriodico > 0) {
          // No tiene cuota para un mes pasado/actual → potencialmente deuda
          tieneDeuda = true;
        }
      }

      cobrado += cobradoAdherente;

      if (esCancelado) {
        // Los cancelados no entran en los contadores de estado activo
      } else if (!tieneCuotas) {
        sinCuota++;
      } else if (tieneDeuda) {
        conDeuda++;
      } else {
        alDia++;
      }
    }

    final restaCobrar = prometidoAnual - cobrado;
    final porcentaje = prometidoAnual > 0 ? (cobrado / prometidoAnual) * 100 : 0.0;

    return {
      'prometido_anual': prometidoAnual,
      'cobrado': cobrado,
      'resta_cobrar': restaCobrar,
      'porcentaje_al_dia': porcentaje,
      'total_adherentes': adherentes.length,
      'con_deuda': conDeuda,
      'al_dia': alDia,
      'sin_cuota': sinCuota,
    };
  }

  /// Registra un pago (confirma cuota existente o la crea si no existe).
  ///
  /// Si la cuota para ese mes ya existe y está ESPERADA, actualiza a CONFIRMADO.
  /// Si no existe cuota, la crea como CONFIRMADO directamente.
  Future<bool> registrarPagoAdhesion({
    required int acuerdoId,
    required int mes,
    required int anio,
    required double monto,
    String? observacion,
    double? cantidadLitros,
    double? precioLitroArs,
  }) async {
    try {
      final db = await AppDatabase.instance();

      // Buscar compromiso vinculado a este acuerdo
      final compromisos = await db.query(
        'compromisos',
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [acuerdoId],
        limit: 1,
      );

      if (compromisos.isEmpty) {
        throw StateError('No se encontró compromiso vinculado al acuerdo $acuerdoId');
      }

      final compromisoId = compromisos.first['id'] as int;
      final fechaProgramada = '$anio-${mes.toString().padLeft(2, '0')}-01';

      // Buscar cuota existente para este mes
      final cuotasExistentes = await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id = ? AND fecha_programada >= ? AND fecha_programada <= ?',
        whereArgs: [
          compromisoId,
          fechaProgramada,
          '$anio-${mes.toString().padLeft(2, '0')}-28', // Tolerancia fin de mes
        ],
      );

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;

      if (cuotasExistentes.isNotEmpty) {
        // Actualizar cuota existente
        final cuotaId = cuotasExistentes.first['id'] as int;
        await db.update(
          'compromiso_cuotas',
          {
            'estado': 'CONFIRMADO',
            'monto_real': monto,
            'cantidad_litros': cantidadLitros,
            'precio_litro_ars': precioLitroArs,
            'updated_ts': now,
          },
          where: 'id = ?',
          whereArgs: [cuotaId],
        );
      } else {
        // Contar cuotas existentes para determinar numero_cuota
        final countResult = await db.rawQuery(
          'SELECT COALESCE(MAX(numero_cuota), 0) as max_num FROM compromiso_cuotas WHERE compromiso_id = ?',
          [compromisoId],
        );
        final nextNum = ((countResult.first['max_num'] as int?) ?? 0) + 1;

        await db.insert('compromiso_cuotas', {
          'compromiso_id': compromisoId,
          'numero_cuota': nextNum,
          'fecha_programada': fechaProgramada,
          'monto_esperado': monto,
          'monto_real': monto,
          'cantidad_litros': cantidadLitros,
          'precio_litro_ars': precioLitroArs,
          'estado': 'CONFIRMADO',
          'created_ts': now,
          'updated_ts': now,
        });
      }

      // Actualizar cuotas_confirmadas en compromiso
      final confirmadasResult = await db.rawQuery(
        "SELECT COUNT(*) as total FROM compromiso_cuotas WHERE compromiso_id = ? AND estado = 'CONFIRMADO'",
        [compromisoId],
      );
      final totalConfirmadas = (confirmadasResult.first['total'] as int?) ?? 0;

      await db.update(
        'compromisos',
        {
          'cuotas_confirmadas': totalConfirmadas,
          'updated_ts': now,
        },
        where: 'id = ?',
        whereArgs: [compromisoId],
      );

      // Enqueue sync_outbox
      await db.insert('sync_outbox', {
        'tipo': 'compromiso_cuota',
        'ref': '$compromisoId-$anio-$mes',
        'payload': '{"compromiso_id":$compromisoId,"anio":$anio,"mes":$mes,"monto":$monto}',
        'estado': 'PENDIENTE',
        'reintentos': 0,
        'created_ts': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      return true;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_service.registrar_pago',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdoId': acuerdoId, 'mes': mes, 'anio': anio, 'monto': monto},
      );
      return false;
    }
  }

  /// Calcula totales por mes para la fila TOTAL de la tabla pivot.
  ///
  /// Retorna mapa { mes: { 'esperado': double, 'cobrado': double } }
  Map<int, Map<String, double>> calcularTotalesPorMes(
      List<Map<String, dynamic>> adherentes) {
    final totales = <int, Map<String, double>>{};

    for (int mes = 1; mes <= 12; mes++) {
      double esperado = 0;
      double cobrado = 0;

      for (final adherente in adherentes) {
        final montoPeriodico = (adherente['monto_periodico'] as num?)?.toDouble() ?? 0.0;
        final cuotasMap = adherente['cuotas'] as Map<int, Map<String, dynamic>>? ?? {};
        final cuota = cuotasMap[mes];

        esperado += montoPeriodico;
        if (cuota != null && cuota['estado'] == 'CONFIRMADO') {
          cobrado += (cuota['monto_real'] as num?)?.toDouble()
              ?? (cuota['monto_esperado'] as num?)?.toDouble()
              ?? 0.0;
        }
      }

      totales[mes] = {'esperado': esperado, 'cobrado': cobrado};
    }

    return totales;
  }

  /// Obtiene el compromisoId vinculado a un acuerdo.
  /// Retorna null si no se encuentra.
  Future<int?> obtenerCompromisoIdDeAcuerdo(int acuerdoId) async {
    try {
      final db = await AppDatabase.instance();
      final compromisos = await db.query(
        'compromisos',
        columns: ['id'],
        where: 'acuerdo_id = ? AND eliminado = 0',
        whereArgs: [acuerdoId],
        limit: 1,
      );
      if (compromisos.isEmpty) return null;
      return compromisos.first['id'] as int;
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_service.obtener_compromiso_id',
        error: e.toString(),
        stackTrace: stack,
        payload: {'acuerdoId': acuerdoId},
      );
      return null;
    }
  }

  /// Retorna las subcategorías de la categoría ADHE que tienen al menos
  /// un acuerdo cargado (es_adhesion=1, tipo=INGRESO, no eliminado).
  /// Solo se muestran tabs para las subcategorías con datos reales.
  Future<List<Map<String, dynamic>>> obtenerSubcategoriasConDatos({
    int? unidadGestionId,
  }) async {
    try {
      final db = await AppDatabase.instance();

      var existsWhere =
          "a.subcategoria_id = s.id AND a.categoria = 'ADHE' AND a.tipo = 'INGRESO' AND a.eliminado = 0";
      final args = <dynamic>[];

      if (unidadGestionId != null) {
        existsWhere += ' AND a.unidad_gestion_id = ?';
        args.add(unidadGestionId);
      }

      final rows = await db.rawQuery('''
        SELECT s.id, s.nombre, s.orden
        FROM subcategorias s
        WHERE s.categoria_id = (
          SELECT id FROM categoria_movimiento WHERE codigo = 'ADHE' LIMIT 1
        )
        AND EXISTS (
          SELECT 1 FROM acuerdos a WHERE $existsWhere
        )
        ORDER BY s.orden ASC
      ''', args);

      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_service.obtener_subcategorias',
        error: e.toString(),
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Obtiene adherentes con sus pagos mensuales para un año,
  /// filtrados por subcategoría (ADHE + subcategoria_id).
  Future<List<Map<String, dynamic>>> obtenerAdherentesPorSubcategoria({
    required int anio,
    required int subcategoriaId,
    int? unidadGestionId,
  }) async {
    try {
      final db = await AppDatabase.instance();

      final whereClause = StringBuffer(
        "a.subcategoria_id = ? AND a.categoria = 'ADHE' AND a.tipo = 'INGRESO' AND a.eliminado = 0",
      );
      final whereArgs = <dynamic>[subcategoriaId];

      if (unidadGestionId != null) {
        whereClause.write(' AND a.unidad_gestion_id = ?');
        whereArgs.add(unidadGestionId);
      }

      final acuerdos = await db.rawQuery('''
        SELECT
          a.id AS acuerdo_id,
          a.nombre,
          a.monto_periodico,
          a.monto_total,
          a.modalidad,
          a.cuotas,
          a.unidad,
          a.activo,
          a.fecha_fin,
          a.tipo,
          a.categoria,
          ep.nombre AS entidad_nombre
        FROM acuerdos a
        LEFT JOIN entidades_plantel ep ON ep.id = a.entidad_plantel_id
        WHERE $whereClause
        ORDER BY a.activo DESC, a.nombre ASC
      ''', whereArgs);

      if (acuerdos.isEmpty) return [];

      final acuerdoIds = acuerdos.map((a) => a['acuerdo_id']).toList();
      final placeholders = acuerdoIds.map((_) => '?').join(',');
      final fechaDesde = '$anio-01-01';
      final fechaHasta = '$anio-12-31';

      final cuotas = await db.rawQuery('''
        SELECT
          c.acuerdo_id,
          cc.numero_cuota,
          cc.fecha_programada,
          cc.monto_esperado,
          cc.monto_real,
          cc.estado,
          cc.id AS cuota_id,
          cc.compromiso_id
        FROM compromiso_cuotas cc
        INNER JOIN compromisos c ON c.id = cc.compromiso_id
        WHERE c.acuerdo_id IN ($placeholders)
          AND cc.fecha_programada >= ?
          AND cc.fecha_programada <= ?
          AND c.eliminado = 0
        ORDER BY cc.fecha_programada ASC
      ''', [...acuerdoIds, fechaDesde, fechaHasta]);

      final cuotasPorAcuerdo = <int, Map<int, Map<String, dynamic>>>{};
      for (final cuota in cuotas) {
        final acuerdoId = cuota['acuerdo_id'] as int;
        final fechaStr = cuota['fecha_programada'] as String;
        final mes = DateTime.parse(fechaStr).month;
        cuotasPorAcuerdo.putIfAbsent(acuerdoId, () => {});
        cuotasPorAcuerdo[acuerdoId]![mes] = {
          'cuota_id': cuota['cuota_id'],
          'numero_cuota': cuota['numero_cuota'],
          'compromiso_id': cuota['compromiso_id'],
          'estado': cuota['estado'],
          'monto_esperado': (cuota['monto_esperado'] as num?)?.toDouble() ?? 0.0,
          'monto_real': (cuota['monto_real'] as num?)?.toDouble(),
          'fecha_programada': fechaStr,
        };
      }

      return acuerdos.map((a) {
        final acuerdoId = a['acuerdo_id'] as int;
        final montoPeriodico = (a['monto_periodico'] as num?)?.toDouble() ?? 0.0;
        return {
          'acuerdo_id': acuerdoId,
          'nombre': a['nombre']?.toString() ?? 'Sin nombre',
          'entidad_nombre': a['entidad_nombre']?.toString() ?? '—',
          'monto_periodico': montoPeriodico,
          'unidad': a['unidad']?.toString() ?? 'ARS',
          'activo': a['activo'] ?? 1,
          'fecha_fin': a['fecha_fin']?.toString(),
          'tipo': a['tipo']?.toString() ?? 'INGRESO',
          'categoria': a['categoria']?.toString() ?? '',
          'cuotas': cuotasPorAcuerdo[acuerdoId] ?? <int, Map<String, dynamic>>{},
        };
      }).toList();
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesiones_service.obtener_por_subcategoria',
        error: e.toString(),
        stackTrace: stack,
        payload: {'anio': anio, 'subcategoriaId': subcategoriaId},
      );
      return [];
    }
  }
}
