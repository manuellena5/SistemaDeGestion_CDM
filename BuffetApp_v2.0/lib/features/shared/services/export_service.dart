import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// Public Downloads via third-party plugins removed due to AGP namespace issues.
import 'package:share_plus/share_plus.dart';
import 'package:file_saver/file_saver.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import '../../../data/dao/db.dart';
import '../../../domain/safe_map.dart';
import '../../buffet/services/caja_service.dart';
import '../../../app_version.dart';
import 'package:excel/excel.dart';

class ExportService {
  final _df = DateFormat("yyyy-MM-dd'T'HH:mm:ss");

  String _csvEscape(String v) {
    final needsQuotes = v.contains(',') || v.contains('\n') || v.contains('"');
    var s = v.replaceAll('"', '""');
    return needsQuotes ? '"$s"' : s;
  }

  String _rowsToCsv(List<List<String>> rows) {
    return rows.map((r) => r.map(_csvEscape).join(',')).join('\n') + '\n';
  }

  Future<Directory> _ensureExportDir() async {
    // Forzar prioridad absoluta a carpeta pública de Descargas
    // Nota: En Android modernos, esta ruta suele ser /storage/emulated/0/Download.
    Directory? base;
    try {
      final dl = Directory('/storage/emulated/0/Download');
      if (await dl.exists()) {
        base = dl; // preferimos SIEMPRE esta
      }
    } catch (_) {
      base = null;
    }
    // Si no existe, intentar con path_provider (puede devolver carpeta privada de app)
    if (base == null) {
      try {
        final dirs = await getExternalStorageDirectories(
            type: StorageDirectory.downloads);
        if (dirs != null && dirs.isNotEmpty) {
          base = dirs.first;
        } else {
          base = await getExternalStorageDirectory();
        }
      } catch (_) {
        base = null;
      }
    }
    base ??= Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'exports'));
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  Future<Map<String, dynamic>> _buildPayload(Database db, int cajaId) async {
    try {
      final caja = await db.query('caja_diaria',
          where: 'id=?', whereArgs: [cajaId], limit: 1);
      if (caja.isEmpty) throw Exception('Caja no encontrada');

      final resumen = await CajaService().resumenCaja(cajaId);
      final tickets = await db.rawQuery('''
        SELECT t.id, t.identificador_ticket, t.status, t.total_ticket, t.fecha_hora,
               p.id AS producto_id, p.codigo_producto, p.nombre AS producto_nombre,
               v.metodo_pago_id, mp.descripcion AS metodo_pago_desc
        FROM tickets t
        JOIN ventas v ON v.id = t.venta_id
        LEFT JOIN products p ON p.id = t.producto_id
        LEFT JOIN metodos_pago mp ON mp.id = v.metodo_pago_id
        WHERE v.caja_id = ?
        ORDER BY t.id ASC
      ''', [cajaId]);

      final ventasPorProducto = await db.rawQuery('''
        SELECT p.id AS producto_id, p.codigo_producto, p.nombre AS producto_nombre,
               COUNT(*) AS cantidad, SUM(t.total_ticket) AS total
        FROM tickets t
        JOIN ventas v ON v.id = t.venta_id
        LEFT JOIN products p ON p.id = t.producto_id
        WHERE v.caja_id = ? AND t.status <> 'Anulado'
        GROUP BY p.id, p.codigo_producto, p.nombre
        ORDER BY cantidad DESC
      ''', [cajaId]);

      final catalogo = await db.rawQuery('''
        SELECT p.id, p.codigo_producto, p.nombre, c.descripcion AS categoria
        FROM products p
        LEFT JOIN Categoria_Producto c ON c.id = p.categoria_id
        WHERE p.visible = 1
        ORDER BY p.id ASC
      ''');

      final nowIso = _df.format(DateTime.now());
      final metadata = {
        'app': 'BuffetMirror',
        'app_version': '${AppBuildInfo.version}+${AppBuildInfo.buildNumber}',
        'device_id': 'unknown',
        'device_alias': 'device',
        'fecha_export': nowIso,
      };

      final movimientos = await db.query('caja_movimiento',
          where: 'caja_id=?', whereArgs: [cajaId], orderBy: 'created_ts ASC');

      return {
        'metadata': metadata,
        'caja': caja.first,
        'resumen': resumen,
        'totales_por_mp': resumen['por_mp'],
        'tickets': tickets,
        'ventas_por_producto': ventasPorProducto,
        'movimientos': movimientos,
        'catalogo': catalogo,
      };
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.buildPayload',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<File> exportCajaToJson(int cajaId) async {
    try {
      final exportDir = await _ensureExportDir();
      final db = await AppDatabase.instance();
      final payload = await _buildPayload(db, cajaId);
      final codigo =
          (payload['caja'] as Map)['codigo_caja']?.toString() ?? 'CAJA';
      final file = File(p.join(exportDir.path, 'caja_$codigo.json'));
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(payload),
          flush: true);
      return file;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajaJson',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<void> shareCajaFile(int cajaId) async {
    try {
      final file = await exportCajaToJson(cajaId);
      final base = p.basename(file.path);
      await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path)],
          subject: 'Caja $base',
          title: 'Caja $base'));
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.shareCaja',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<File> exportCajaToCsv(int cajaId, {String? directoryPath}) async {
    try {
      final exportDir = directoryPath != null
          ? Directory(directoryPath)
          : await _ensureExportDir();
      final db = await AppDatabase.instance();
      final payload = await _buildPayload(db, cajaId);
      final caja = Map<String, Object?>.from(payload['caja'] as Map);
      final resumen = Map<String, Object?>.from(payload['resumen'] as Map);
      final totalesMp =
          List<Map<String, Object?>>.from(payload['totales_por_mp'] as List);
      final porProducto = List<Map<String, Object?>>.from(
          payload['ventas_por_producto'] as List);
      final movimientos =
          List<Map<String, Object?>>.from(payload['movimientos'] as List);
      final codigo = caja['codigo_caja']?.toString() ?? 'CAJA';

      final headers = [
        'Codigo de caja',
        'Estado',
        'Fecha',
        'Hora apertura',
        'Unidad de gestión',
        'Desc Evento',
        'Caj Apertura',
        'Caj cierre',
        'Total Ventas',
        'Fondo Inicial',
        'Efectivo declarado en caja',
        'Diferencia',
        'Entradas vendidas',
        'Tickets emitidos',
        'Tickets anulados',
        'Ventas Efectivo',
        'Ventas Transferencia',
        'Ventas por producto',
        'Ingresos',
        'Retiros',
        'Ticket promedio'
      ];

      double ventasEfec = 0.0, ventasTransf = 0.0;
      for (final m in totalesMp) {
        final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
        final monto = ((m['total'] as num?) ?? 0).toDouble();
        if (desc.contains('efectivo'))
          ventasEfec += monto;
        else if (desc.contains('transfer')) ventasTransf += monto;
      }

      final productosConcat = porProducto.map((p) {
        final nom = (p['producto_nombre'] ?? p['nombre'] ?? '').toString();
        final cant = ((p['cantidad'] as num?) ?? 0).toInt();
        final tot = ((p['total'] as num?) ?? 0).toInt();
        return '$nom x $cant = $tot';
      }).join(' ; ');

      double ing = 0.0, ret = 0.0;
      for (final m in movimientos) {
        final tipo = (m['tipo'] ?? '').toString().toUpperCase();
        final monto = ((m['monto'] as num?) ?? 0).toDouble();
        if (tipo == 'INGRESO')
          ing += monto;
        else if (tipo == 'RETIRO') ret += monto;
      }

      final avgRows = await db.rawQuery('''
        SELECT AVG(total_venta_no_anulados) AS avg_ticket
        FROM (
          SELECT v.id, SUM(t.total_ticket) AS total_venta_no_anulados
          FROM ventas v
          JOIN tickets t ON t.venta_id = v.id AND t.status <> 'Anulado'
          WHERE v.caja_id = ?
          GROUP BY v.id
        )
      ''', [cajaId]);
      final avgTicket =
          (avgRows.isNotEmpty && (avgRows.first['avg_ticket'] as num?) != null)
              ? ((avgRows.first['avg_ticket'] as num).toDouble())
              : 0.0;

      final tks = Map<String, Object?>.from(resumen['tickets'] as Map);
      final values = [
        caja['codigo_caja']?.toString() ?? '',
        caja['estado']?.toString() ?? '',
        caja['fecha']?.toString() ?? '',
        caja['hora_apertura']?.toString() ?? '',
        caja['disciplina']?.toString() ?? '',
        caja['descripcion_evento']?.toString() ?? '',
        caja['cajero_apertura']?.toString() ?? '',
        caja['cajero_cierre']?.toString() ?? '',
        (((resumen['total'] as num?) ?? 0)).toString(),
        (((caja['fondo_inicial'] as num?) ?? 0)).toString(),
        (((caja['conteo_efectivo_final'] as num?) ?? 0)).toString(),
        (((caja['diferencia'] as num?) ?? 0)).toString(),
        ((((caja['entradas'] as num?) ?? 0)).toInt()).toString(),
        (((tks['emitidos'] as num?) ?? 0).toInt()).toString(),
        (((tks['anulados'] as num?) ?? 0).toInt()).toString(),
        ventasEfec.toString(),
        ventasTransf.toString(),
        productosConcat,
        ing.toString(),
        ret.toString(),
        avgTicket.toStringAsFixed(2),
      ];

      final csv = _rowsToCsv([headers, values]);
      final file = File(p.join(exportDir.path, 'caja_${codigo}.csv'));
      await file.writeAsString(csv, flush: true);
      return file;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajaCsv',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<String> saveCsvToDownloadsViaMediaStore(int cajaId) async {
    try {
      final db = await AppDatabase.instance();
      final payload = await _buildPayload(db, cajaId);
      final caja = Map<String, Object?>.from(payload['caja'] as Map);
      final resumen = Map<String, Object?>.from(payload['resumen'] as Map);
      final totalesMp =
          List<Map<String, Object?>>.from(payload['totales_por_mp'] as List);
      final porProducto = List<Map<String, Object?>>.from(
          payload['ventas_por_producto'] as List);
      final movimientos =
          List<Map<String, Object?>>.from(payload['movimientos'] as List);
      final codigo = caja['codigo_caja']?.toString() ?? 'CAJA';

      final headers = [
        'Codigo de caja',
        'Estado',
        'Fecha',
        'Hora apertura',
        'Unidad de gestión',
        'Desc Evento',
        'Caj Apertura',
        'Caj cierre',
        'Total Ventas',
        'Fondo Inicial',
        'Efectivo declarado en caja',
        'Diferencia',
        'Entradas vendidas',
        'Tickets emitidos',
        'Tickets anulados',
        'Ventas Efectivo',
        'Ventas Transferencia',
        'Ventas por producto',
        'Ingresos',
        'Retiros',
        'Ticket promedio'
      ];

      double ventasEfec = 0.0, ventasTransf = 0.0;
      for (final m in totalesMp) {
        final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
        final monto = ((m['total'] as num?) ?? 0).toDouble();
        if (desc.contains('efectivo'))
          ventasEfec += monto;
        else if (desc.contains('transfer')) ventasTransf += monto;
      }

      final productosConcat = porProducto.map((p) {
        final nom = (p['producto_nombre'] ?? p['nombre'] ?? '').toString();
        final cant = ((p['cantidad'] as num?) ?? 0).toInt();
        final tot = ((p['total'] as num?) ?? 0).toInt();
        return '$nom x $cant = $tot';
      }).join(' ; ');

      double ing = 0.0, ret = 0.0;
      for (final m in movimientos) {
        final tipo = (m['tipo'] ?? '').toString().toUpperCase();
        final monto = ((m['monto'] as num?) ?? 0).toDouble();
        if (tipo == 'INGRESO')
          ing += monto;
        else if (tipo == 'RETIRO') ret += monto;
      }

      final avgRows = await db.rawQuery('''
        SELECT AVG(total_venta_no_anulados) AS avg_ticket
        FROM (
          SELECT v.id, SUM(t.total_ticket) AS total_venta_no_anulados
          FROM ventas v
          JOIN tickets t ON t.venta_id = v.id AND t.status <> 'Anulado'
          WHERE v.caja_id = ?
          GROUP BY v.id
        )
      ''', [cajaId]);
      final avgTicket =
          (avgRows.isNotEmpty && (avgRows.first['avg_ticket'] as num?) != null)
              ? ((avgRows.first['avg_ticket'] as num).toDouble())
              : 0.0;

      final tks = Map<String, Object?>.from(resumen['tickets'] as Map);
      final values = [
        caja['codigo_caja']?.toString() ?? '',
        caja['estado']?.toString() ?? '',
        caja['fecha']?.toString() ?? '',
        caja['hora_apertura']?.toString() ?? '',
        caja['disciplina']?.toString() ?? '',
        caja['descripcion_evento']?.toString() ?? '',
        caja['cajero_apertura']?.toString() ?? '',
        caja['cajero_cierre']?.toString() ?? '',
        (((resumen['total'] as num?) ?? 0)).toString(),
        (((caja['fondo_inicial'] as num?) ?? 0)).toString(),
        (((caja['conteo_efectivo_final'] as num?) ?? 0)).toString(),
        (((caja['diferencia'] as num?) ?? 0)).toString(),
        ((((caja['entradas'] as num?) ?? 0)).toInt()).toString(),
        (((tks['emitidos'] as num?) ?? 0).toInt()).toString(),
        (((tks['anulados'] as num?) ?? 0).toInt()).toString(),
        ventasEfec.toString(),
        ventasTransf.toString(),
        productosConcat,
        ing.toString(),
        ret.toString(),
        avgTicket.toStringAsFixed(2),
      ];

      final csvString = _rowsToCsv([headers, values]);
      final bytes = Uint8List.fromList(csvString.codeUnits);
      final name = '$codigo';
      final savedPath = await FileSaver.instance.saveFile(
        name: name,
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.text,
      );
      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajaCsvMediaStore',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<void> openFile(String path) async {
    await OpenFilex.open(path);
  }

  Future<File> exportCajaToCsvInDownloads(int cajaId) async {
    try {
      // Prioridad: carpeta pública de Descargas
      Directory? exportDir;
      try {
        final dl = Directory('/storage/emulated/0/Download');
        if (await dl.exists()) {
          exportDir = dl;
        }
      } catch (_) {
        exportDir = null;
      }
      // Si no existe, usar path_provider como alternativa
      if (exportDir == null) {
        try {
          final dirs = await getExternalStorageDirectories(
              type: StorageDirectory.downloads);
          if (dirs != null && dirs.isNotEmpty) {
            exportDir = dirs.first;
          }
        } catch (_) {
          exportDir = null;
        }
      }
      exportDir ??= await _ensureExportDir();
      return exportCajaToCsv(cajaId, directoryPath: exportDir.path);
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajaCsvDownloads',
          error: e,
          stackTrace: st,
          payload: {'cajaId': cajaId});
      rethrow;
    }
  }

  Future<void> shareCajaCsv(int cajaId) async {
    final file = await exportCajaToCsv(cajaId);
    final base = p.basename(file.path);
    await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)], subject: 'Caja $base', title: 'Caja $base'));
  }

  Future<File> exportVisibleCajasToCsvInDownloads() async {
    try {
      Directory? exportDir;
      try {
        final dl = Directory('/storage/emulated/0/Download');
        if (await dl.exists()) {
          exportDir = dl;
        }
      } catch (_) {
        exportDir = null;
      }
      if (exportDir == null) {
        try {
          final dirs = await getExternalStorageDirectories(
              type: StorageDirectory.downloads);
          if (dirs != null && dirs.isNotEmpty) {
            exportDir = dirs.first;
          }
        } catch (_) {
          exportDir = null;
        }
      }
      exportDir ??= await _ensureExportDir();

      final db = await AppDatabase.instance();
      final cajas = await db.query('caja_diaria',
          where: 'visible = 1', orderBy: 'fecha DESC, id DESC');

      final headers = [
        'Codigo de caja',
        'Estado',
        'Fecha',
        'Hora apertura',
        'Unidad de gestión',
        'Desc Evento',
        'Caj Apertura',
        'Caj cierre',
        'Total Ventas',
        'Fondo Inicial',
        'Efectivo declarado en caja',
        'Diferencia',
        'Entradas vendidas',
        'Tickets emitidos',
        'Tickets anulados',
        'Ventas Efectivo',
        'Ventas Transferencia',
        'Ventas por producto',
        'Ingresos',
        'Retiros',
        'Ticket promedio'
      ];

      final rows = <List<String>>[headers];
      for (final caja in cajas) {
        final cajaId = (caja['id'] as num).toInt();
        final payloadResumen = await _buildPayload(db, cajaId);
        final resumen =
            Map<String, Object?>.from(payloadResumen['resumen'] as Map);
        final totalesMp = List<Map<String, Object?>>.from(
            payloadResumen['totales_por_mp'] as List);
        final porProducto = List<Map<String, Object?>>.from(
            payloadResumen['ventas_por_producto'] as List);
        final movimientos = List<Map<String, Object?>>.from(
            payloadResumen['movimientos'] as List);

        double ventasEfec = 0.0, ventasTransf = 0.0;
        for (final m in totalesMp) {
          final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
          final monto = ((m['total'] as num?) ?? 0).toDouble();
          if (desc.contains('efectivo'))
            ventasEfec += monto;
          else if (desc.contains('transfer')) ventasTransf += monto;
        }

        final productosConcat = porProducto.map((p) {
          final nom = (p['producto_nombre'] ?? p['nombre'] ?? '').toString();
          final cant = ((p['cantidad'] as num?) ?? 0).toInt();
          final tot = ((p['total'] as num?) ?? 0).toInt();
          return '$nom x $cant = $tot';
        }).join(' ; ');

        double ing = 0.0, ret = 0.0;
        for (final m in movimientos) {
          final tipo = (m['tipo'] ?? '').toString().toUpperCase();
          final monto = ((m['monto'] as num?) ?? 0).toDouble();
          if (tipo == 'INGRESO')
            ing += monto;
          else if (tipo == 'RETIRO') ret += monto;
        }

        final avgRows = await db.rawQuery('''
          SELECT AVG(total_venta_no_anulados) AS avg_ticket
          FROM (
            SELECT v.id, SUM(t.total_ticket) AS total_venta_no_anulados
            FROM ventas v
            JOIN tickets t ON t.venta_id = v.id AND t.status <> 'Anulado'
            WHERE v.caja_id = ?
            GROUP BY v.id
          )
        ''', [cajaId]);
        final avgTicket = (avgRows.isNotEmpty &&
                (avgRows.first['avg_ticket'] as num?) != null)
            ? ((avgRows.first['avg_ticket'] as num).toDouble())
            : 0.0;

        final tks = Map<String, Object?>.from(resumen['tickets'] as Map);
        rows.add([
          caja['codigo_caja']?.toString() ?? '',
          caja['estado']?.toString() ?? '',
          caja['fecha']?.toString() ?? '',
          caja['hora_apertura']?.toString() ?? '',
          caja['disciplina']?.toString() ?? '',
          caja['descripcion_evento']?.toString() ?? '',
          caja['cajero_apertura']?.toString() ?? '',
          caja['cajero_cierre']?.toString() ?? '',
          (((resumen['total'] as num?) ?? 0)).toString(),
          (((caja['fondo_inicial'] as num?) ?? 0)).toString(),
          (((caja['conteo_efectivo_final'] as num?) ?? 0)).toString(),
          (((caja['diferencia'] as num?) ?? 0)).toString(),
          ((((caja['entradas'] as num?) ?? 0)).toInt()).toString(),
          (((tks['emitidos'] as num?) ?? 0).toInt()).toString(),
          (((tks['anulados'] as num?) ?? 0).toInt()).toString(),
          ventasEfec.toString(),
          ventasTransf.toString(),
          productosConcat,
          ing.toString(),
          ret.toString(),
          avgTicket.toStringAsFixed(2),
        ]);
      }

      final csv = _rowsToCsv(rows);
      final file = File(p.join(exportDir.path, 'cajas_historial.csv'));
      await file.writeAsString(csv, flush: true);
      return file;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajasCsvDownloads', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<String> saveVisibleCajasCsvToDownloadsViaMediaStore() async {
    try {
      final db = await AppDatabase.instance();
      final cajas = await db.query('caja_diaria',
          where: 'visible = 1', orderBy: 'fecha DESC, id DESC');

      final headers = [
        'Codigo de caja',
        'Estado',
        'Fecha',
        'Hora apertura',
        'Unidad de gestión',
        'Desc Evento',
        'Caj Apertura',
        'Caj cierre',
        'Total Ventas',
        'Fondo Inicial',
        'Efectivo declarado en caja',
        'Diferencia',
        'Entradas vendidas',
        'Tickets emitidos',
        'Tickets anulados',
        'Ventas Efectivo',
        'Ventas Transferencia',
        'Ventas por producto',
        'Ingresos',
        'Retiros',
        'Ticket promedio'
      ];
      final rows = <List<String>>[headers];

      for (final caja in cajas) {
        final cajaId = (caja['id'] as num).toInt();
        final payloadResumen = await _buildPayload(db, cajaId);
        final resumen =
            Map<String, Object?>.from(payloadResumen['resumen'] as Map);
        final totalesMp = List<Map<String, Object?>>.from(
            payloadResumen['totales_por_mp'] as List);
        final porProducto = List<Map<String, Object?>>.from(
            payloadResumen['ventas_por_producto'] as List);
        final movimientos = List<Map<String, Object?>>.from(
            payloadResumen['movimientos'] as List);

        double ventasEfec = 0.0, ventasTransf = 0.0;
        for (final m in totalesMp) {
          final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
          final monto = ((m['total'] as num?) ?? 0).toDouble();
          if (desc.contains('efectivo'))
            ventasEfec += monto;
          else if (desc.contains('transfer')) ventasTransf += monto;
        }
        final productosConcat = porProducto.map((p) {
          final nom = (p['producto_nombre'] ?? p['nombre'] ?? '').toString();
          final cant = ((p['cantidad'] as num?) ?? 0).toInt();
          final tot = ((p['total'] as num?) ?? 0).toInt();
          return '$nom x $cant = $tot';
        }).join(' ; ');
        double ing = 0.0, ret = 0.0;
        for (final m in movimientos) {
          final tipo = (m['tipo'] ?? '').toString().toUpperCase();
          final monto = ((m['monto'] as num?) ?? 0).toDouble();
          if (tipo == 'INGRESO')
            ing += monto;
          else if (tipo == 'RETIRO') ret += monto;
        }
        final avgRows = await db.rawQuery('''
          SELECT AVG(total_venta_no_anulados) AS avg_ticket
          FROM (
            SELECT v.id, SUM(t.total_ticket) AS total_venta_no_anulados
            FROM ventas v
            JOIN tickets t ON t.venta_id = v.id AND t.status <> 'Anulado'
            WHERE v.caja_id = ?
            GROUP BY v.id
          )
        ''', [cajaId]);
        final avgTicket = (avgRows.isNotEmpty &&
                (avgRows.first['avg_ticket'] as num?) != null)
            ? ((avgRows.first['avg_ticket'] as num).toDouble())
            : 0.0;
        final tks = Map<String, Object?>.from(resumen['tickets'] as Map);
        rows.add([
          caja['codigo_caja']?.toString() ?? '',
          caja['estado']?.toString() ?? '',
          caja['fecha']?.toString() ?? '',
          caja['hora_apertura']?.toString() ?? '',
          caja['disciplina']?.toString() ?? '',
          caja['descripcion_evento']?.toString() ?? '',
          caja['cajero_apertura']?.toString() ?? '',
          caja['cajero_cierre']?.toString() ?? '',
          (((resumen['total'] as num?) ?? 0)).toString(),
          (((caja['fondo_inicial'] as num?) ?? 0)).toString(),
          (((caja['conteo_efectivo_final'] as num?) ?? 0)).toString(),
          (((caja['diferencia'] as num?) ?? 0)).toString(),
          ((((caja['entradas'] as num?) ?? 0)).toInt()).toString(),
          (((tks['emitidos'] as num?) ?? 0).toInt()).toString(),
          (((tks['anulados'] as num?) ?? 0).toInt()).toString(),
          ventasEfec.toString(),
          ventasTransf.toString(),
          productosConcat,
          ing.toString(),
          ret.toString(),
          avgTicket.toStringAsFixed(2),
        ]);
      }

      final csvString = _rowsToCsv(rows);
      final bytes = Uint8List.fromList(csvString.codeUnits);
      final savedPath = await FileSaver.instance.saveFile(
        name: 'cajas_historial',
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.text,
      );
      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
          scope: 'export.cajasCsvMediaStore', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Exporta movimientos de tesorería a CSV
  Future<String> exportMovimientosCSV({
    required List<Map<String, dynamic>> movimientos,
    required String filename,
    String? unidadGestionNombre,
  }) async {
    try {
      final rows = <List<String>>[
        // Header
        [
          'ID',
          'Fecha',
          'Tipo',
          'Categoría',
          'Monto',
          'Medio de Pago',
          'Compromiso',
          'Estado',
          'Observación',
          'Estado Sync',
          'Fecha Modificación',
        ],
      ];

      for (final mov in movimientos) {
        final ts = mov['created_ts'];
        DateTime? fecha;
        if (ts is int) {
          fecha = DateTime.fromMillisecondsSinceEpoch(ts);
        } else if (ts is String) {
          fecha = DateTime.tryParse(ts);
        }

        final updTs = mov['updated_ts'];
        DateTime? fechaMod;
        if (updTs is int) {
          fechaMod = DateTime.fromMillisecondsSinceEpoch(updTs);
        }

        rows.add([
          (mov['id']?.toString() ?? ''),
          (fecha != null ? DateFormat('dd/MM/yyyy HH:mm').format(fecha) : ''),
          (mov['tipo']?.toString() ?? ''),
          (mov['categoria']?.toString() ?? ''),
          (mov['monto']?.toString() ?? '0'),
          (mov['medio_pago_desc']?.toString() ?? ''),
          (mov['compromiso_nombre']?.toString() ?? ''),
          (mov['estado']?.toString() ?? 'CONFIRMADO'),
          (mov['observacion']?.toString() ?? ''),
          (mov['sync_estado']?.toString() ?? ''),
          (fechaMod != null
              ? DateFormat('dd/MM/yyyy HH:mm').format(fechaMod)
              : ''),
        ]);
      }

      final csvString = _rowsToCsv(rows);
      final bytes = Uint8List.fromList(utf8.encode(csvString));

      // Limpiar nombre de archivo
      final cleanFilename = filename
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(' ', '_');

      final savedPath = await FileSaver.instance.saveFile(
        name: cleanFilename.replaceAll('.csv', ''),
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.text,
      );

      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'export.movimientosCsv',
        error: e,
        stackTrace: st,
        payload: {'count': movimientos.length, 'unidad': unidadGestionNombre},
      );
      rethrow;
    }
  }

  /// Exporta movimientos de tesorería a Excel con 2 hojas:
  /// - Hoja 1: Movimientos detallados
  /// - Hoja 2: Resumen del mes
  Future<String> exportMovimientosExcel({
    required List<Map<String, dynamic>> movimientos,
    required String filename,
    String? unidadGestionNombre,
    required DateTime mes,
    required double saldoInicial,
    required double totalIngresos,
    required double totalEgresos,
    required double saldoFinal,
    required double proyeccionPendiente,
  }) async {
    try {
      final excel = Excel.createExcel();

      // Eliminar hoja por defecto
      excel.delete('Sheet1');

      // === HOJA 1: MOVIMIENTOS ===
      final sheetMovimientos = excel['Movimientos'];

      // Estilos para headers
      final headerStyle = CellStyle(
        bold: true,
        backgroundColorHex: '#2E7D32',
        fontColorHex: '#FFFFFF',
      );

      // Headers
      final headers = [
        'Fecha',
        'Tipo',
        'Categoría',
        'Monto',
        'Estado',
        'Compromiso',
        'Observación',
      ];

      for (var i = 0; i < headers.length; i++) {
        final cell = sheetMovimientos
            .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = headers[i];
        cell.cellStyle = headerStyle;
      }

      // Datos
      var rowIndex = 1;
      for (final mov in movimientos) {
        final ts = mov['created_ts'];
        DateTime? fecha;
        if (ts is int) {
          fecha = DateTime.fromMillisecondsSinceEpoch(ts);
        } else if (ts is String) {
          fecha = DateTime.tryParse(ts);
        }

        final tipo = (mov['tipo'] ?? '').toString();
        final monto = (mov['monto'] as num?)?.toDouble() ?? 0.0;

        // Fila
        sheetMovimientos
                .cell(CellIndex.indexByColumnRow(
                    columnIndex: 0, rowIndex: rowIndex))
                .value =
            fecha != null ? DateFormat('dd/MM/yyyy HH:mm').format(fecha) : '';

        sheetMovimientos
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex))
            .value = tipo;
        sheetMovimientos
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIndex))
            .value = (mov['categoria']?.toString() ?? '');

        final cellMonto = sheetMovimientos.cell(
            CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIndex));
        cellMonto.value = monto;
        cellMonto.cellStyle = CellStyle(
          fontColorHex: tipo == 'INGRESO' ? '#2E7D32' : '#C62828',
          bold: true,
        );

        sheetMovimientos
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIndex))
            .value = (mov['estado']?.toString() ?? 'CONFIRMADO');
        sheetMovimientos
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowIndex))
            .value = (mov['compromiso_nombre']?.toString() ?? '');
        sheetMovimientos
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: rowIndex))
            .value = (mov['observacion']?.toString() ?? '');

        rowIndex++;
      }

      // Ajustar ancho de columnas
      for (var i = 0; i < headers.length; i++) {
        sheetMovimientos.setColWidth(i, i == 6 ? 40.0 : 20.0);
      }

      // === HOJA 2: RESUMEN DEL MES ===
      final sheetResumen = excel['Resumen del Mes'];

      // Título
      final tituloCell = sheetResumen
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0));
      tituloCell.value =
          'Resumen Mensual - ${DateFormat('MMMM yyyy', 'es_AR').format(mes)}';
      tituloCell.cellStyle = CellStyle(
        bold: true,
        fontSize: 16,
        fontColorHex: '#2E7D32',
      );

      if (unidadGestionNombre != null) {
        final unidadCell = sheetResumen
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1));
        unidadCell.value = 'Unidad de Gestión: $unidadGestionNombre';
        unidadCell.cellStyle = CellStyle(italic: true);
      }

      var resumenRow = 3;

      // Saldo Inicial
      final labelSaldoInicialCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: resumenRow));
      labelSaldoInicialCell.value = 'Saldo Inicial (arrastre):';
      labelSaldoInicialCell.cellStyle = CellStyle(bold: true);

      final valorSaldoInicialCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: resumenRow));
      valorSaldoInicialCell.value = saldoInicial;
      valorSaldoInicialCell.cellStyle = CellStyle(
        fontColorHex: '#424242',
        bold: true,
      );

      resumenRow++;

      // Ingresos del mes
      final labelIngresosCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: resumenRow));
      labelIngresosCell.value = 'Ingresos del mes:';
      labelIngresosCell.cellStyle = CellStyle(bold: true);

      final valorIngresosCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: resumenRow));
      valorIngresosCell.value = totalIngresos;
      valorIngresosCell.cellStyle = CellStyle(
        fontColorHex: '#2E7D32',
        bold: true,
      );

      resumenRow++;

      // Egresos del mes
      final labelEgresosCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: resumenRow));
      labelEgresosCell.value = 'Egresos del mes:';
      labelEgresosCell.cellStyle = CellStyle(bold: true);

      final valorEgresosCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: resumenRow));
      valorEgresosCell.value = -totalEgresos;
      valorEgresosCell.cellStyle = CellStyle(
        fontColorHex: '#C62828',
        bold: true,
      );

      resumenRow++;
      resumenRow++; // Línea en blanco

      // Saldo Final
      final labelSaldoFinalCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: resumenRow));
      labelSaldoFinalCell.value = 'Saldo Final del mes:';
      labelSaldoFinalCell.cellStyle = CellStyle(
        bold: true,
        fontSize: 14,
        backgroundColorHex: '#F5F5F5',
      );

      final valorSaldoFinalCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: resumenRow));
      valorSaldoFinalCell.value = saldoFinal;
      valorSaldoFinalCell.cellStyle = CellStyle(
        bold: true,
        fontSize: 14,
        fontColorHex: saldoFinal >= 0 ? '#2E7D32' : '#C62828',
        backgroundColorHex: '#F5F5F5',
      );

      resumenRow++;
      resumenRow++; // Línea en blanco

      // Proyección Pendiente
      final labelProyeccionCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: resumenRow));
      labelProyeccionCell.value = 'Proyección pendiente:';
      labelProyeccionCell.cellStyle = CellStyle(
        bold: true,
        italic: true,
      );

      final valorProyeccionCell = sheetResumen.cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: resumenRow));
      valorProyeccionCell.value = proyeccionPendiente;
      valorProyeccionCell.cellStyle = CellStyle(
        bold: true,
        italic: true,
        fontColorHex: proyeccionPendiente >= 0 ? '#2E7D32' : '#C62828',
      );

      // Ajustar ancho de columnas en resumen
      sheetResumen.setColWidth(0, 30.0);
      sheetResumen.setColWidth(1, 25.0);

      // Guardar archivo
      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Error al generar archivo Excel');
      }

      // Limpiar nombre de archivo
      final cleanFilename = filename
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(' ', '_')
          .replaceAll('.csv', '')
          .replaceAll('.xlsx', '');

      final savedPath = await FileSaver.instance.saveFile(
        name: cleanFilename,
        bytes: Uint8List.fromList(excelBytes),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'export.movimientosExcel',
        error: e,
        stackTrace: st,
        payload: {'count': movimientos.length, 'unidad': unidadGestionNombre},
      );
      rethrow;
    }
  }

  /// FASE 35: Exportar reporte mensual de plantel a Excel
  /// Genera archivo con hoja "Resumen" (tabla de entidades) y hoja "Totales"
  Future<String> exportPlantelMensualExcel({
    required List<Map<String, dynamic>> entidades,
    required int mes,
    required int anio,
    required double totalComprometido,
    required double totalPagado,
    required double totalPendiente,
    required String filename,
  }) async {
    try {
      final excel = Excel.createExcel();

      // Eliminar hoja por defecto
      if (excel.tables.containsKey('Sheet1')) {
        excel.delete('Sheet1');
      }

      // ===== HOJA 1: RESUMEN (Tabla de entidades) =====
      final sheetResumen = excel['Resumen'];

      // Cabeceras
      final headers = [
        'Nombre',
        'Rol',
        'Total Mensual',
        'Pagado',
        'Pendiente',
        'Total'
      ];
      for (var i = 0; i < headers.length; i++) {
        final cell = sheetResumen
            .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = headers[i];
        cell.cellStyle = CellStyle(
          bold: true,
          backgroundColorHex: '#1976D2',
          fontColorHex: '#FFFFFF',
        );
      }

      // Datos de entidades
      for (var i = 0; i < entidades.length; i++) {
        final entidad = entidades[i];
        final nombre = entidad['nombre']?.toString() ?? '';
        final rol = _nombreRolCorto(entidad['rol']?.toString() ?? '');
        final totalComprometidoEntidad =
            (entidad['totalComprometido'] as num?)?.toDouble() ?? 0.0;
        final pagado = (entidad['pagado'] as num?)?.toDouble() ?? 0.0;
        final esperado = (entidad['esperado'] as num?)?.toDouble() ?? 0.0;
        final total = pagado + esperado;

        final rowIndex = i + 1;

        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex))
            .value = nombre;
        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex))
            .value = rol;
        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIndex))
            .value = totalComprometidoEntidad;
        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIndex))
            .value = pagado;
        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIndex))
            .value = esperado;
        sheetResumen
            .cell(
                CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowIndex))
            .value = total;

        // Colores para valores monetarios
        if (pagado > 0) {
          sheetResumen
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 3, rowIndex: rowIndex))
              .cellStyle = CellStyle(
            fontColorHex: '#2E7D32', // Verde
            bold: true,
          );
        }

        if (esperado > 0) {
          sheetResumen
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 4, rowIndex: rowIndex))
              .cellStyle = CellStyle(
            fontColorHex: '#F57C00', // Naranja
            bold: true,
          );
        }
      }

      // Ajustar anchos de columnas
      sheetResumen.setColWidth(0, 30.0);
      sheetResumen.setColWidth(1, 20.0);
      sheetResumen.setColWidth(2, 18.0);
      sheetResumen.setColWidth(3, 18.0);
      sheetResumen.setColWidth(4, 18.0);
      sheetResumen.setColWidth(5, 18.0);

      // ===== HOJA 2: TOTALES =====
      final sheetTotales = excel['Totales'];

      // Título
      final mesNombre = _nombreMes(mes);
      final tituloCell = sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0));
      tituloCell.value = 'Resumen General - $mesNombre $anio';
      tituloCell.cellStyle = CellStyle(
        bold: true,
        fontSize: 14,
      );

      // Espacio
      var row = 2;

      // Total Comprometido
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = 'Total Comprometido:';
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .cellStyle = CellStyle(bold: true);
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = totalComprometido;
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .cellStyle = CellStyle(
        fontColorHex: '#1976D2',
        bold: true,
      );
      row++;

      // Total Pagado
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = 'Total Pagado:';
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .cellStyle = CellStyle(bold: true);
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = totalPagado;
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .cellStyle = CellStyle(
        fontColorHex: '#2E7D32',
        bold: true,
      );
      row++;

      // Total Pendiente
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = 'Total Pendiente:';
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .cellStyle = CellStyle(bold: true);
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = totalPendiente;
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .cellStyle = CellStyle(
        fontColorHex: '#F57C00',
        bold: true,
      );
      row++;

      // Espacio
      row++;

      // Cantidad de Entidades
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = 'Cantidad de Entidades:';
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .cellStyle = CellStyle(bold: true);
      sheetTotales
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = entidades.length;

      // Ajustar anchos
      sheetTotales.setColWidth(0, 30.0);
      sheetTotales.setColWidth(1, 25.0);

      // Guardar archivo
      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Error al generar archivo Excel');
      }

      // Limpiar nombre de archivo
      final cleanFilename = filename
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(' ', '_')
          .replaceAll('.xlsx', '');

      final savedPath = await FileSaver.instance.saveFile(
        name: cleanFilename,
        bytes: Uint8List.fromList(excelBytes),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'export.plantelMensualExcel',
        error: e,
        stackTrace: st,
        payload: {'count': entidades.length, 'mes': mes, 'anio': anio},
      );
      rethrow;
    }
  }

  String _nombreRolCorto(String rol) {
    switch (rol) {
      case 'JUGADOR':
        return 'Jugador';
      case 'DT':
        return 'DT';
      case 'AYUDANTE':
        return 'Ayudante';
      case 'PF':
        return 'PF';
      case 'OTRO':
        return 'Otro';
      default:
        return rol;
    }
  }

  String _nombreMes(int mes) {
    const meses = [
      'Enero',
      'Febrero',
      'Marzo',
      'Abril',
      'Mayo',
      'Junio',
      'Julio',
      'Agosto',
      'Septiembre',
      'Octubre',
      'Noviembre',
      'Diciembre'
    ];
    return meses[mes - 1];
  }

  // ─── EXPORTAR CAJA A EXCEL ────────────────────────────────────────

  /// Exporta el detalle completo de una caja cerrada a Excel (.xlsx).
  ///
  /// Genera un archivo con una sola hoja que contiene:
  /// - Detalle del evento (disciplina, fecha, cajeros, etc.)
  /// - Totales de ventas (global, efectivo, transferencia)
  /// - Movimientos de caja (fondo, ingresos, retiros)
  /// - Ventas por producto (tabla con nombre, cantidad, total)
  /// - Datos de cierre (efectivo declarado, transferencias, diferencia)
  Future<String> exportCajaExcel(int cajaId) async {
    try {
      final db = await AppDatabase.instance();
      final payload = await _buildPayload(db, cajaId);
      final caja = Map<String, Object?>.from(payload['caja'] as Map);
      final resumen = Map<String, Object?>.from(payload['resumen'] as Map);
      final totalesMp =
          List<Map<String, Object?>>.from(payload['totales_por_mp'] as List);
      final porProducto = List<Map<String, Object?>>.from(
          payload['ventas_por_producto'] as List);
      final movimientos =
          List<Map<String, Object?>>.from(payload['movimientos'] as List);

      final codigo = caja['codigo_caja']?.toString() ?? 'CAJA';
      final fecha = caja['fecha']?.toString() ?? '';
      final disciplina = caja['disciplina']?.toString() ?? '';
      final horaApertura = caja['hora_apertura']?.toString() ?? '';
      final cajeroApertura = caja['cajero_apertura']?.toString() ?? '';
      final cajeroCierre = caja['cajero_cierre']?.toString() ?? '';
      final descripcionEvento =
          (caja['descripcion_evento'] as String?)?.trim() ?? '';
      final obsApertura =
          (caja['observaciones_apertura'] as String?)?.trim() ?? '';
      final obsCierre = (caja['obs_cierre'] as String?)?.trim() ?? '';
      final estado = caja['estado']?.toString() ?? '';

      final fondo = ((caja['fondo_inicial'] as num?) ?? 0).toDouble();
      final efectivoDeclarado =
          ((caja['conteo_efectivo_final'] as num?) ?? 0).toDouble();
      final transferenciasFinal =
          (((caja['conteo_transferencias_final'] as num?) ??
                      (caja['transferencias_final'] as num?)) ??
                  0)
              .toDouble();
      final entradasVendidas = ((caja['entradas'] as num?) ?? 0).toInt();

      final totalVentas = ((resumen['total'] as num?) ?? 0).toDouble();
      final ticketsEmitidos =
          ((resumen['tickets'] as Map?)?['emitidos'] as num?)?.toInt() ?? 0;
      final ticketsAnulados =
          ((resumen['tickets'] as Map?)?['anulados'] as num?)?.toInt() ?? 0;

      double ventasEfec = 0.0;
      double ventasTransf = 0.0;
      for (final m in totalesMp) {
        final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
        final monto = ((m['total'] as num?) ?? 0).toDouble();
        if (desc.contains('efectivo')) ventasEfec += monto;
        if (desc.contains('transfer')) ventasTransf += monto;
      }

      double movIngresos = 0.0;
      double movRetiros = 0.0;
      for (final m in movimientos) {
        final tipo = (m['tipo'] ?? '').toString().toUpperCase();
        final monto = ((m['monto'] as num?) ?? 0).toDouble();
        if (tipo == 'INGRESO') movIngresos += monto;
        if (tipo == 'RETIRO') movRetiros += monto;
      }

      // Ordenar productos por cantidad desc
      porProducto.sort((a, b) {
        final an = (a['cantidad'] as num?) ?? 0;
        final bn = (b['cantidad'] as num?) ?? 0;
        return bn.compareTo(an);
      });

      // ─── CREAR EXCEL ───
      final excel = Excel.createExcel();
      excel.delete('Sheet1');
      final sheet = excel['Resumen de Caja'];

      final headerStyle = CellStyle(
        bold: true,
        backgroundColorHex: '#2E7D32',
        fontColorHex: '#FFFFFF',
      );
      final sectionStyle = CellStyle(
        bold: true,
        fontSize: 13,
        fontColorHex: '#2E7D32',
      );
      final labelStyle = CellStyle(bold: true);
      final moneyGreenStyle = CellStyle(bold: true, fontColorHex: '#2E7D32');
      final moneyRedStyle = CellStyle(bold: true, fontColorHex: '#C62828');

      var row = 0;

      // ─── TÍTULO ───
      void _title(String text) {
        final c = sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
        c.value = text;
        c.cellStyle =
            CellStyle(bold: true, fontSize: 16, fontColorHex: '#1B5E20');
        row++;
      }

      void _section(String text) {
        row++; // línea en blanco
        final c = sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
        c.value = text;
        c.cellStyle = sectionStyle;
        row++;
      }

      void _labelValue(String label, String value) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = label
          ..cellStyle = labelStyle;
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
            .value = value;
        row++;
      }

      void _labelMoney(String label, double value, {bool negative = false}) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = label
          ..cellStyle = labelStyle;
        final c = sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row));
        c.value = value;
        c.cellStyle = negative ? moneyRedStyle : moneyGreenStyle;
        row++;
      }

      // ─── DETALLE DEL EVENTO ───
      _title('Resumen de Caja - $codigo');
      row++;
      _section('DETALLE DEL EVENTO');
      _labelValue('Código de Caja', codigo);
      _labelValue('Fecha', fecha);
      _labelValue('Hora Apertura', horaApertura);
      _labelValue('Unidad de gestión', disciplina.isEmpty ? '—' : disciplina);
      _labelValue('Descripción Evento',
          descripcionEvento.isEmpty ? '—' : descripcionEvento);
      _labelValue(
          'Cajero Apertura', cajeroApertura.isEmpty ? '—' : cajeroApertura);
      _labelValue('Cajero Cierre', cajeroCierre.isEmpty ? '—' : cajeroCierre);
      if (obsApertura.isNotEmpty) _labelValue('Obs. Apertura', obsApertura);
      _labelValue('Estado', estado);

      // ─── TOTAL DE VENTAS ───
      _section('TOTAL DE VENTAS');
      _labelMoney('Total Ventas', totalVentas);
      _labelMoney('Ventas Efectivo', ventasEfec);
      _labelMoney('Ventas Transferencia', ventasTransf);
      _labelValue('Tickets Emitidos', '$ticketsEmitidos');
      _labelValue('Tickets Anulados', '$ticketsAnulados');

      // ─── MOVIMIENTOS DE CAJA ───
      _section('MOVIMIENTOS DE CAJA');
      _labelMoney('Fondo Inicial', fondo);
      _labelMoney('Ingresos', movIngresos);
      _labelMoney('Retiros', movRetiros, negative: true);

      // ─── VENTAS POR PRODUCTO ───
      _section('VENTAS POR PRODUCTO');

      // Header de tabla
      final prodHeaders = ['Producto', 'Cantidad', 'Total'];
      for (var i = 0; i < prodHeaders.length; i++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row))
          ..value = prodHeaders[i]
          ..cellStyle = headerStyle;
      }
      row++;

      for (final p in porProducto) {
        final nom = (p['producto_nombre'] ?? p['nombre'] ?? '').toString();
        final cant = ((p['cantidad'] as num?) ?? 0).toInt();
        final tot = ((p['total'] as num?) ?? 0).toDouble();

        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = nom;
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
            .value = cant;
        final totCell = sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row));
        totCell.value = tot;
        totCell.cellStyle = CellStyle(bold: true);
        row++;
      }

      if (porProducto.isEmpty) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = 'Sin ventas registradas';
        row++;
      }

      // ─── DETALLE DE MOVIMIENTOS ───
      _section('DETALLE DE MOVIMIENTOS');
      if (movimientos.isEmpty) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = 'Sin movimientos registrados';
        row++;
      } else {
        final movHeaders = [
          'Fecha/Hora',
          'Tipo',
          'Monto',
          'Medio de Pago',
          'Observación'
        ];
        for (var i = 0; i < movHeaders.length; i++) {
          sheet
              .cell(
                  CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row))
            ..value = movHeaders[i]
            ..cellStyle = headerStyle;
        }
        row++;
        for (final m in movimientos) {
          final tipo = (m['tipo'] ?? '').toString().toUpperCase();
          final monto = ((m['monto'] as num?) ?? 0).toDouble();
          final medioPago =
              (m['medio_pago_desc'] ?? m['medio_pago'] ?? '').toString();
          final obs = (m['observacion'] as String?)?.trim() ?? '';
          String fechaHora = '';
          final ts = m['created_ts'];
          if (ts != null) {
            try {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                      (ts as num).toInt(),
                      isUtc: true)
                  .toLocal();
              fechaHora =
                  '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            } catch (_) {}
          }
          sheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 0, rowIndex: row))
              .value = fechaHora;
          final tipoCell = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row));
          tipoCell.value = tipo;
          tipoCell.cellStyle = CellStyle(
              fontColorHex:
                  tipo == 'INGRESO' ? '#2E7D32' : '#C62828');
          final montoCell = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row));
          montoCell.value = monto;
          montoCell.cellStyle = CellStyle(
              bold: true,
              fontColorHex:
                  tipo == 'INGRESO' ? '#2E7D32' : '#C62828');
          sheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 3, rowIndex: row))
              .value = medioPago;
          sheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 4, rowIndex: row))
              .value = obs;
          row++;
        }
      }

      // ─── CONCILIACIÓN POR MEDIO DE PAGO ───
      _section('CONCILIACIÓN POR MEDIO DE PAGO');

      // -- Efectivo --
      final cajaEsperada = fondo + ventasEfec + movIngresos - movRetiros;
      final difEfectivo = efectivoDeclarado - cajaEsperada;
      {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'EFECTIVO'
          ..cellStyle = CellStyle(bold: true, fontSize: 11);
        row++;
      }
      _labelMoney('Efectivo esperado', cajaEsperada);
      _labelMoney('Efectivo declarado', efectivoDeclarado);
      _labelMoney('Diferencia efectivo', difEfectivo,
          negative: difEfectivo < 0);
      row++;

      // -- Transferencias --
      final transfEsperadas = ventasTransf;
      final difTransf = transferenciasFinal - transfEsperadas;
      {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'TRANSFERENCIAS'
          ..cellStyle = CellStyle(bold: true, fontSize: 11);
        row++;
      }
      _labelMoney('Transf. esperadas', transfEsperadas);
      _labelMoney('Transf. declaradas', transferenciasFinal);
      _labelMoney('Diferencia transf.', difTransf, negative: difTransf < 0);
      row++;

      // -- Diferencia Total --
      final difTotal = difEfectivo + difTransf;
      {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'DIFERENCIA TOTAL DEL EVENTO'
          ..cellStyle = CellStyle(
              bold: true,
              fontSize: 12,
              fontColorHex: difTotal >= 0 ? '#1B5E20' : '#C62828');
        final dtCell = sheet.cell(
            CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row));
        dtCell.value = difTotal;
        dtCell.cellStyle = CellStyle(
            bold: true,
            fontSize: 12,
            fontColorHex: difTotal >= 0 ? '#1B5E20' : '#C62828');
        row++;
      }
      _labelValue('', '(Suma de diferencias por medio de pago)');
      _labelValue('Entradas Vendidas',
          entradasVendidas == 0 ? '—' : '$entradasVendidas');
      if (obsCierre.isNotEmpty) _labelValue('Obs. Cierre', obsCierre);

      // ─── RESULTADO ECONÓMICO DEL EVENTO ───
      _section('RESULTADO ECONÓMICO DEL EVENTO');
      final resultadoNeto = ventasEfec + ventasTransf + movIngresos - movRetiros - fondo;
      _labelMoney('Ventas en Efectivo', ventasEfec);
      _labelMoney('Ventas por Transferencia', ventasTransf);
      _labelMoney('Otros Ingresos', movIngresos);
      _labelMoney('Retiros', movRetiros, negative: true);
      _labelMoney('Saldo Inicial', fondo, negative: true);
      row++;
      // Resultado neto con estilo destacado
      {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'RESULTADO NETO'
          ..cellStyle = CellStyle(bold: true, fontSize: 14, fontColorHex: resultadoNeto >= 0 ? '#1B5E20' : '#C62828');
        final rnCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row));
        rnCell.value = resultadoNeto;
        rnCell.cellStyle = CellStyle(bold: true, fontSize: 14, fontColorHex: resultadoNeto >= 0 ? '#1B5E20' : '#C62828');
        row++;
      }

      // ─── RESULTADO NETO + DIFERENCIAS ───
      row++;
      {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'RESULTADO NETO + DIFERENCIAS'
          ..cellStyle = CellStyle(bold: true, fontSize: 12);
        row++;
      }
      _labelMoney('Diferencia efectivo', difEfectivo, negative: difEfectivo < 0);
      _labelMoney('Diferencia transferencias', difTransf, negative: difTransf < 0);
      row++;
      {
        final resultadoConDif = resultadoNeto + difEfectivo + difTransf;
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          ..value = 'TOTAL (RESULTADO + DIFERENCIAS)'
          ..cellStyle = CellStyle(bold: true, fontSize: 14, fontColorHex: resultadoConDif >= 0 ? '#1B5E20' : '#C62828');
        final totalCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row));
        totalCell.value = resultadoConDif;
        totalCell.cellStyle = CellStyle(bold: true, fontSize: 14, fontColorHex: resultadoConDif >= 0 ? '#1B5E20' : '#C62828');
        row++;
      }

      // ─── ANCHOS DE COLUMNAS ───
      sheet.setColWidth(0, 30.0);
      sheet.setColWidth(1, 25.0);
      sheet.setColWidth(2, 20.0);

      // ─── GUARDAR ───
      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Error al generar archivo Excel');
      }

      final cleanCodigo =
          codigo.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').replaceAll(' ', '_');

      final savedPath = await FileSaver.instance.saveFile(
        name: 'caja_$cleanCodigo',
        bytes: Uint8List.fromList(excelBytes),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      return savedPath;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'export.cajaExcel',
        error: e,
        stackTrace: st,
        payload: {'cajaId': cajaId},
      );
      rethrow;
    }
  }
}
