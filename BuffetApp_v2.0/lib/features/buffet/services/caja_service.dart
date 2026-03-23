import '../../../data/dao/db.dart';
import '../../../domain/safe_map.dart';
import '../../shared/services/supabase_sync_service.dart';

class CajaService {
  static String? puntoVentaFromCodigoCaja(String codigoCaja) {
    final s = codigoCaja.trim();
    if (s.isEmpty) return null;
    final idx = s.indexOf('-');
    if (idx <= 0) return null;
    return s.substring(0, idx).trim();
  }

  Future<List<Map<String, dynamic>>> listarPuntosVenta() async {
    try {
      final db = await AppDatabase.instance();
      final r = await db.query('punto_venta', orderBy: 'codigo ASC');
      return r.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.listarPV', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<List<String>> listarDisciplinas() async {
    try {
      final db = await AppDatabase.instance();
      final r = await db.query('disciplinas',
          columns: ['nombre'], orderBy: 'id ASC');
      return r.map((e) => e.safeString('nombre')).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.listarDisciplinas', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getCajaAbierta() async {
    try {
      final db = await AppDatabase.instance();
      final r =
          await db.query('caja_diaria', where: "estado = 'ABIERTA'", limit: 1);
      return r.isNotEmpty ? r.first : null;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.getAbierta', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<int> abrirCaja(
      {required String usuario,
      required double fondoInicial,
      required String disciplina,
      required String descripcionEvento,
      String? observacion,
      required String puntoVentaCodigo}) async {
    try {
      final db = await AppDatabase.instance();
      final now = DateTime.now();
      final fecha =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final hora =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      String discCode = 'OTRO';
      final discLower = disciplina.toLowerCase();
      if (discLower.contains('infantil')) {
        discCode = 'FUTI';
      } else if (discLower.contains('senior')) {
        discCode = 'FUTS';
      } else if (discLower.contains('mayor')) {
        discCode = 'FUTM';
      } else if (discLower.contains('vóley') || discLower.contains('voley')) {
        discCode = 'VOL';
      } else if (discLower.contains('patín') || discLower.contains('patin')) {
        discCode = 'PAT';
      } else if (discLower.contains('tenis')) {
        discCode = 'TEN';
      } else if (discLower.contains('comisión') || discLower.contains('comision') || discLower.contains('directiva')) {
        discCode = 'CDIR';
      } else if (discLower.contains('evento')) {
        discCode = 'EVEN';
      }
      final fechaCompact = fecha.replaceAll('-', '');
      final baseCodigo = '$puntoVentaCodigo-$fechaCompact-$discCode';
      // Generar código único: si existe el base, agregar sufijo -2, -3, ...
      String codigo = baseCodigo;
      final existentes = await db.query(
        'caja_diaria',
        columns: ['codigo_caja'],
        where: 'codigo_caja LIKE ?',
        whereArgs: ['$baseCodigo%'],
      );
      if (existentes.isNotEmpty) {
        int maxSufijo = 1; // 1 implica que existe el base sin sufijo
        for (final row in existentes) {
          final cc = row.safeString('codigo_caja');
          if (cc == baseCodigo) {
            if (maxSufijo < 1) maxSufijo = 1;
            continue;
          }
          if (cc.startsWith('$baseCodigo-')) {
            final parts = cc.split('-');
            final last = parts.isNotEmpty ? parts.last : '';
            final n = int.tryParse(last);
            if (n != null && n > maxSufijo) {
              maxSufijo = n;
            }
          }
        }
        // si encontramos el base usado (maxSufijo>=1), proponer el siguiente entero
        if (maxSufijo >= 1) {
          codigo = '$baseCodigo-${maxSufijo + 1}';
        }
      }
      final newId = await db.insert('caja_diaria', {
        'codigo_caja': codigo,
        'disciplina': disciplina,
        'fecha': fecha,
        // Guardar usuario clásico como 'admin' por defecto
        'usuario_apertura': 'admin',
        // Nuevo campo cajero_apertura
        'cajero_apertura': usuario,
        'hora_apertura': hora,
        'apertura_dt': '$fecha $hora',
        'fondo_inicial': fondoInicial,
        'estado': 'ABIERTA',
        'descripcion_evento': descripcionEvento,
        'observaciones_apertura': (observacion ?? ''),
        'diferencia': 0,
        // Nota: columnas esperadas en Supabase -> 'ingresos' y 'retiros'
        'ingresos': 0,
        'retiros': 0,
        'total_tickets': 0,
        'tickets_anulados': 0,
        'entradas': null,
      });
      // Encolar apertura para sync (idempotente por codigo_caja)
      await SupaSyncService.I.enqueueCaja({
        'codigo_caja': codigo,
        'caja_local_id': newId,
        'disciplina': disciplina,
        'fecha_apertura': '$fecha $hora',
        'usuario_apertura': 'admin',
        'cajero_apertura': usuario,
        'fondo_inicial': fondoInicial,
        'ingresos': 0,
        'retiros': 0,
        'total_efectivo_teorico':
            fondoInicial, // ventas en efectivo = 0 al abrir
        'estado': 'ABIERTA',
        'descripcion_evento': descripcionEvento,
        'observaciones_apertura': (observacion ?? ''),
        'tickets': 0,
        'tickets_anulados': 0,
      });
      return newId;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'caja.abrir',
        error: e,
        stackTrace: st,
        payload: {
          'usuario': usuario,
          'fondoInicial': fondoInicial,
          'disciplina': disciplina,
          'puntoVenta': puntoVentaCodigo,
        },
      );
      rethrow;
    }
  }

  /// Guarda una observación post-cierre con la fecha/hora UTC actual.
  Future<void> guardarObsPostCierre({
    required int cajaId,
    required String observacion,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final ts = AppDatabase.nowUtcSqlString();
      await db.update(
        'caja_diaria',
        {
          'obs_post_cierre': observacion.trim().isEmpty ? null : observacion.trim(),
          'obs_post_cierre_ts': observacion.trim().isEmpty ? null : ts,
          'updated_ts': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id=?',
        whereArgs: [cajaId],
      );
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'caja_service.guardarObsPostCierre',
        error: e,
        stackTrace: st,
        payload: {'cajaId': cajaId},
      );
      rethrow;
    }
  }

  Future<void> cerrarCaja(
      {required int cajaId,
      required double efectivoEnCaja,
      required double transferencias,
      required String usuarioCierre,
      String? observacion,
      int? entradas}) async {
    try {
      final db = await AppDatabase.instance();
      final now = DateTime.now();
      final hora =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      // calcular diferencia: (efectivo + transferencias) - totalVentasSistema (excluyendo tickets anulados)
      final tot = await db.rawQuery('''
      SELECT COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado'
    ''', [cajaId]);
      final totalVentas = tot.first.safeDouble('total');
      // Ventas por efectivo (para total_efectivo_teorico)
      final tef = await db.rawQuery('''
      SELECT COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      JOIN metodos_pago m ON m.id = v.metodo_pago_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado' AND LOWER(m.descripcion) = 'efectivo'
    ''', [cajaId]);
      final totalEfectivoVentas =
          tef.first.safeDouble('total');
      // Tickets emitidos (sin contar anulados)
      final tk = await db.rawQuery('''
      SELECT COALESCE(COUNT(1),0) as c
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado'
    ''', [cajaId]);
      final totalTicketsEmitidos = tk.first.safeInt('c');
      // Fórmula ajustada (incluye ingresos/retiros):
      // Diferencia = ((Efectivo - Fondo - Ingresos + Retiros) + Transferencias) - TotalVentas
      final cajaRow = await db.query('caja_diaria',
          columns: [
            'fondo_inicial',
            'codigo_caja',
            'fecha',
            'apertura_dt',
            'disciplina',
            'descripcion_evento',
            'observaciones_apertura',
            'cajero_apertura'
          ],
          where: 'id=?',
          whereArgs: [cajaId],
          limit: 1);
      final fondo = cajaRow.first.safeDouble('fondo_inicial');
      // Obtener totales de movimientos para aplicar fórmula ajustada
      final movTotals = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN tipo='INGRESO' THEN monto END),0) as ingresos,
        COALESCE(SUM(CASE WHEN tipo='RETIRO' THEN monto END),0) as retiros
      FROM caja_movimiento
      WHERE caja_id = ?
    ''', [cajaId]);
      final ingresos = movTotals.first.safeDouble('ingresos');
      final retiros = movTotals.first.safeDouble('retiros');
      // Obtener desglose por medio de pago
      double ingEfec = 0.0;
      double retEfec = 0.0;
      final movMpTotals = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ing_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ret_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ing_transf,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ret_transf
        FROM caja_movimiento cm
        LEFT JOIN metodos_pago mp ON mp.id = cm.medio_pago_id
        WHERE cm.caja_id = ?
      ''', [cajaId]);
      ingEfec = movMpTotals.first.safeDouble('ing_efec');
      retEfec = movMpTotals.first.safeDouble('ret_efec');
      // Fórmula con desglose por medio de pago
      final totalPorFormula =
          (efectivoEnCaja - fondo - ingEfec + retEfec) + transferencias;
      final diferencia = totalPorFormula - totalVentas;
      await db.update(
          'caja_diaria',
          {
            'estado': 'CERRADA',
            'hora_cierre': hora,
            'cierre_dt':
                '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
            'usuario_cierre': 'admin',
            'cajero_cierre': usuarioCierre,
            'obs_cierre': observacion,
            'conteo_efectivo_final': efectivoEnCaja,
            'conteo_transferencias_final': transferencias,
            // Persistir movimientos para que queden disponibles localmente y para sync.
            'ingresos': ingresos,
            'retiros': retiros,
            'diferencia': diferencia,
            'entradas': entradas,
            'total_tickets': totalTicketsEmitidos,
            // contar anulados aparte
            'tickets_anulados': (await db.rawQuery('''
            SELECT COALESCE(COUNT(1),0) as c
            FROM tickets t
            JOIN ventas v ON v.id = t.venta_id
            WHERE v.caja_id = ? AND t.status = 'Anulado'
          ''', [cajaId])).first['c'] ?? 0,
          },
          where: 'id=?',
          whereArgs: [cajaId]);
      // Encolar cierre (incluye totales y diferencia)
      final codigo = cajaRow.first.safeString('codigo_caja');
      await SupaSyncService.I.enqueueCaja({
        'codigo_caja': codigo,
        'caja_local_id': cajaId,
        'disciplina': cajaRow.first['disciplina'],
        'descripcion_evento': cajaRow.first['descripcion_evento'],
        'fondo_inicial': fondo,
        'fecha_apertura':
            (cajaRow.first['apertura_dt'] ?? cajaRow.first['fecha'])
                ?.toString(),
        'usuario_apertura': 'admin',
        'cajero_apertura': cajaRow.first['cajero_apertura'],
        'observaciones_apertura': cajaRow.first['observaciones_apertura'],
        'fecha_cierre':
            '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
        'usuario_cierre': 'admin',
        'cajero_cierre': usuarioCierre,
        'conteo_efectivo_final': efectivoEnCaja,
        'transferencias_final': transferencias,
        'conteo_transferencias_final': transferencias,
        'total_ventas': totalVentas,
        'total_efectivo_teorico': fondo + totalEfectivoVentas,
        // En Supabase los totales de movimientos se guardan en 'ingresos' y 'retiros'
        'ingresos': ingresos,
        'retiros': retiros,
        'tickets': totalTicketsEmitidos,
        'tickets_anulados': (await db.rawQuery('''
        SELECT COALESCE(COUNT(1),0) as c
        FROM tickets t
        JOIN ventas v ON v.id = t.venta_id
        WHERE v.caja_id = ? AND t.status = 'Anulado'
      ''', [cajaId])).first['c'] ?? 0,
        'diferencia': diferencia,
        'estado': 'CERRADA',
        'obs_cierre': observacion,
        'entradas': entradas,
      });
      // Sync manual por demanda: no forzar aquí
      // Se podría registrar un movimiento resumen si hiciera falta; por ahora solo cerramos estado
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'caja.cerrar',
        error: e,
        stackTrace: st,
        payload: {
          'cajaId': cajaId,
          'efectivo': efectivoEnCaja,
          'transfer': transferencias,
          'usuarioCierre': usuarioCierre,
        },
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>> resumenCaja(int cajaId) async {
    try {
      final db = await AppDatabase.instance();
      final totalPorMp = await db.rawQuery('''
      SELECT v.metodo_pago_id as mp, m.descripcion as mp_desc, COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN metodos_pago m ON m.id = v.metodo_pago_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado'
      GROUP BY v.metodo_pago_id
    ''', [cajaId]);
      final ticketsCont = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN t.status = 'Anulado' THEN 1 ELSE 0 END),0) as anulados,
        COALESCE(SUM(CASE WHEN t.status = 'Impreso' THEN 1 ELSE 0 END),0) as impresos,
        COALESCE(SUM(CASE WHEN t.status = 'No impreso' THEN 1 ELSE 0 END),0) as no_impresos,
        COALESCE(SUM(CASE WHEN t.status <> 'Anulado' THEN 1 ELSE 0 END),0) as emitidos
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id = ?
    ''', [cajaId]);
      final ventasPorProducto = await db.rawQuery('''
      SELECT COALESCE(p.nombre,'(Sin nombre)') AS nombre,
             COUNT(t.id) as cantidad,
             COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN products p ON p.id = t.producto_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado'
      GROUP BY p.id
      ORDER BY cantidad DESC
    ''', [cajaId]);
      final totales = await db.rawQuery('''
      SELECT COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id = ? AND v.activo = 1 AND t.status <> 'Anulado'
    ''', [cajaId]);
      return {
        'total': totales.first['total'] ?? 0,
        'por_mp': totalPorMp,
        'tickets': ticketsCont.isNotEmpty
            ? ticketsCont.first
            : {'anulados': 0, 'impresos': 0, 'no_impresos': 0, 'emitidos': 0},
        'por_producto': ventasPorProducto,
      };
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.resumen',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> listarCajas(
      {bool incluirOcultas = false}) async {
    try {
      final db = await AppDatabase.instance();
      final r = await db.query(
        'caja_diaria',
        columns: [
          'id',
          'codigo_caja',
          'fecha',
          'disciplina',
          'descripcion_evento',
          'observaciones_apertura',
          'estado',
          'apertura_dt',
          'visible',
          'sync_estado'
        ],
        where: incluirOcultas ? null : 'COALESCE(visible,1)=1',
        orderBy: 'apertura_dt DESC, id DESC',
      );
      return r.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.listar', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> listarCajasPorEvento(
      {required String fecha, required String disciplina}) async {
    try {
      final db = await AppDatabase.instance();
      final r = await db.query(
        'caja_diaria',
        where: 'fecha=? AND disciplina=? AND COALESCE(visible,1)=1',
        whereArgs: [fecha, disciplina],
        orderBy: 'apertura_dt ASC, id ASC',
      );
      return r.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.listarPorEvento',
          error: e,
          stackTrace: st,
          payload: {'fecha': fecha, 'disciplina': disciplina});
      rethrow;
    }
  }

  Future<Map<String, dynamic>> resumenCajas(List<int> cajaIds) async {
    if (cajaIds.isEmpty) {
      return {
        'total': 0,
        'por_mp': <Map<String, dynamic>>[],
        'tickets': {
          'anulados': 0,
          'impresos': 0,
          'no_impresos': 0,
          'emitidos': 0
        },
        'por_producto': <Map<String, dynamic>>[],
      };
    }
    try {
      final db = await AppDatabase.instance();
      final placeholders = List.filled(cajaIds.length, '?').join(',');

      final totalPorMp = await db.rawQuery('''
      SELECT v.metodo_pago_id as mp, m.descripcion as mp_desc, COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN metodos_pago m ON m.id = v.metodo_pago_id
      WHERE v.caja_id IN ($placeholders) AND v.activo = 1 AND t.status <> 'Anulado'
      GROUP BY v.metodo_pago_id
    ''', cajaIds);

      final ticketsCont = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN t.status = 'Anulado' THEN 1 ELSE 0 END),0) as anulados,
        COALESCE(SUM(CASE WHEN t.status = 'Impreso' THEN 1 ELSE 0 END),0) as impresos,
        COALESCE(SUM(CASE WHEN t.status = 'No impreso' THEN 1 ELSE 0 END),0) as no_impresos,
        COALESCE(SUM(CASE WHEN t.status <> 'Anulado' THEN 1 ELSE 0 END),0) as emitidos
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id IN ($placeholders)
    ''', cajaIds);

      final ventasPorProducto = await db.rawQuery('''
      SELECT COALESCE(p.nombre,'(Sin nombre)') AS nombre,
             COUNT(t.id) as cantidad,
             COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN products p ON p.id = t.producto_id
      WHERE v.caja_id IN ($placeholders) AND v.activo = 1 AND t.status <> 'Anulado'
      GROUP BY p.id
      ORDER BY cantidad DESC
    ''', cajaIds);

      final totales = await db.rawQuery('''
      SELECT COALESCE(SUM(t.total_ticket),0) as total
      FROM tickets t
      JOIN ventas v ON v.id = t.venta_id
      WHERE v.caja_id IN ($placeholders) AND v.activo = 1 AND t.status <> 'Anulado'
    ''', cajaIds);

      return {
        'total': totales.first['total'] ?? 0,
        'por_mp': totalPorMp,
        'tickets': ticketsCont.isNotEmpty
            ? ticketsCont.first
            : {'anulados': 0, 'impresos': 0, 'no_impresos': 0, 'emitidos': 0},
        'por_producto': ventasPorProducto,
      };
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.resumenCajas',
          error: e,
          stackTrace: st,
          payload: {'cajaIds': cajaIds});
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getCajaById(int id) async {
    try {
      final db = await AppDatabase.instance();
      final r = await db.query('caja_diaria',
          where: 'id=?', whereArgs: [id], limit: 1);
      return r.isNotEmpty ? r.first : null;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.getById', error: e, stackTrace: st, payload: {'id': id});
      rethrow;
    }
  }

  Future<void> setCajaVisible(int id, bool visible) async {
    try {
      final db = await AppDatabase.instance();
      await db.update(
          'caja_diaria',
          {
            'visible': visible ? 1 : 0,
            'updated_ts': DateTime.now().millisecondsSinceEpoch
          },
          where: 'id=?',
          whereArgs: [id]);
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'caja.setVisible',
          error: e,
          stackTrace: st,
          payload: {'id': id, 'visible': visible});
      rethrow;
    }
  }
}
