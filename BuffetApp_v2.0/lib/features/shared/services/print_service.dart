import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../../data/dao/db.dart';
import '../../buffet/services/caja_service.dart';
import 'usb_printer_service.dart';

/// Servicio de impresión/previsualización en formato 80mm
/// Usa el paquete `printing` para abrir el diálogo del sistema o guardar PDF.
class PrintService {
  final _usb = UsbPrinterService();

  /// Usa AppDatabase.medioPagoColumnReady (seteado por _onOpen).
  @Deprecated('H.7: medio_pago_id siempre existe desde v20. Este getter se mantendrá como true.')
  bool get _hasMedioPagoColumn => AppDatabase.medioPagoColumnReady;

  Future<String?> _buildPvLabelFromCajaCodigo(String codigoCaja) async {
    try {
      final pvCodigo = CajaService.puntoVentaFromCodigoCaja(codigoCaja);
      if (pvCodigo == null || pvCodigo.trim().isEmpty) return null;
      final db = await AppDatabase.instance();
      final r = await db.query(
        'punto_venta',
        columns: ['alias_caja'],
        where: 'codigo=?',
        whereArgs: [pvCodigo],
        limit: 1,
      );
      final alias =
          (r.isNotEmpty ? (r.first['alias_caja'] as String?) : null)?.trim() ??
              '';
      return alias.isNotEmpty ? '$pvCodigo - $alias' : pvCodigo;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'print.pv_label',
        error: e,
        stackTrace: st,
        payload: {'codigo_caja': codigoCaja},
      );
      return null;
    }
  }

  // Preferencias de ancho de papel
  Future<int> _preferredPaperWidthMm() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final mm = sp.getInt('paper_width_mm');
      if (mm == 58 || mm == 75 || mm == 80) return mm!;
    } catch (_) {}
    return 80; // por defecto 80mm
  }

  Future<int> _preferredLineWidth() async {
    final mm = await _preferredPaperWidthMm();
    // Línea estimada en caracteres: 58→32, 75→42, 80→48
    if (mm <= 58) return 32;
    if (mm < 80) return 42; // 75mm
    return 48; // 80mm
  }

  Future<PdfPageFormat> _preferredPdfFormat() async {
    final mm = await _preferredPaperWidthMm();
    if (mm == 80) return PdfPageFormat.roll80;
    final width = mm * PdfPageFormat.mm;
    return PdfPageFormat(width, double.infinity);
  }

  /// Construye el PDF de un ticket por ÍTEM
  Future<Uint8List> buildTicketPdf(int ticketId) async {
    final db = await AppDatabase.instance();
    final rows = await db.rawQuery('''
      SELECT t.id, t.identificador_ticket, t.fecha_hora, t.total_ticket, 
             p.nombre as producto, v.caja_id, c.codigo_caja
      FROM tickets t
      JOIN products p ON p.id = t.producto_id
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN caja_diaria c ON c.id = v.caja_id
      WHERE t.id = ?
    ''', [ticketId]);
    if (rows.isEmpty) {
      // PDF vacío con mensaje
      final doc = pw.Document();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (ctx) =>
            pw.Center(child: pw.Text('Ticket no encontrado: #$ticketId')),
      ));
      return doc.save();
    }
    final t = rows.first;
    final identificador =
        (t['identificador_ticket'] as String?) ?? '#${t['id']}';
    final fechaHora = (t['fecha_hora'] as String?) ?? '';
    final cajaCodigo = (t['codigo_caja'] as String?) ?? '-';
    final producto = (t['producto'] as String?) ?? 'Producto';
    final total = (t['total_ticket'] as num?)?.toDouble() ?? 0;

    final doc = pw.Document();
    final bold = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
    final header = pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold);

    doc.addPage(
      pw.Page(
        pageFormat: await _preferredPdfFormat(),
        margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Center(child: pw.Text('Buffet - C.D.M', style: header)),
              pw.SizedBox(height: 2),
              pw.Text(identificador),
              pw.Text(fechaHora),
              pw.Text(cajaCodigo),
              pw.SizedBox(height: 10),
              pw.Text(producto.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: 26, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text(_formatCurrency(total), style: bold),
            ],
          );
        },
      ),
    );
    return doc.save();
  }

  /// Construye el PDF del cierre/resumen de caja
  Future<Uint8List> buildCajaResumenPdf(int cajaId) async {
    final db = await AppDatabase.instance();
    final caja = await db.query('caja_diaria',
        where: 'id=?', whereArgs: [cajaId], limit: 1);
    final resumen = await CajaService().resumenCaja(cajaId);
    final movimientos = await db.rawQuery('''
            SELECT cm.*, mp.descripcion as medio_pago_desc
            FROM caja_movimiento cm
            LEFT JOIN metodos_pago mp ON mp.id = cm.medio_pago_id
            WHERE cm.caja_id=?
            ORDER BY cm.created_ts ASC
          ''', [cajaId]);
    // Desglose de movimientos por medio de pago
    double movIngEfec = 0.0, movRetEfec = 0.0, movIngTransf = 0.0, movRetTransf = 0.0;
    {
      final movMpTotals = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ing_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ret_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ing_transf,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ret_transf
        FROM caja_movimiento cm
        LEFT JOIN metodos_pago mp ON mp.id = cm.medio_pago_id
        WHERE cm.caja_id=?
      ''', [cajaId]);
      movIngEfec = (movMpTotals.first['ing_efec'] as num?)?.toDouble() ?? 0.0;
      movRetEfec = (movMpTotals.first['ret_efec'] as num?)?.toDouble() ?? 0.0;
      movIngTransf = (movMpTotals.first['ing_transf'] as num?)?.toDouble() ?? 0.0;
      movRetTransf = (movMpTotals.first['ret_transf'] as num?)?.toDouble() ?? 0.0;
    }
    final c = caja.isNotEmpty ? caja.first : <String, Object?>{};
    final fondo = ((c['fondo_inicial'] as num?) ?? 0).toDouble();
    final efectivoDeclarado =
        ((c['conteo_efectivo_final'] as num?) ?? 0).toDouble();
    final transferenciasDeclaradasPdf =
        ((c['conteo_transferencias_final'] as num?) ?? 0).toDouble();
    final obsApertura = (c['observaciones_apertura'] as String?) ?? '';
    final obsCierre = (c['obs_cierre'] as String?) ?? '';
    final obsPostCierre = ((c['obs_post_cierre'] as String?) ?? '').trim();
    final obsPostCierreTs = ((c['obs_post_cierre_ts'] as String?) ?? '').trim();
    final descripcionEvento = (c['descripcion_evento'] as String?) ?? '';
    final diferencia = ((c['diferencia'] as num?) ?? 0).toDouble();
    final int? entradasVendidas = (c['entradas'] as num?)?.toInt();
    final codigoCaja = (c['codigo_caja'] ?? '').toString();
    final pvLabel = codigoCaja.trim().isNotEmpty
        ? await _buildPvLabelFromCajaCodigo(codigoCaja)
        : null;

    final doc = pw.Document();
    pw.TextStyle s([bool b = false]) => pw.TextStyle(
        fontSize: 9, fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal);

    String line([String title = '', String? value]) {
      if (value == null) return title;
      return '$title $value';
    }

    final totalesMp = (resumen['por_mp'] as List).cast<Map<String, Object?>>();
    final porProd =
        (resumen['por_producto'] as List).cast<Map<String, Object?>>();

    // Cargar icono de la app para incluirlo pequeño en el PDF
    pw.ImageProvider? logo;
    try {
      logo = await imageFromAssetBundle('assets/icons/app_icon_foreground.png');
    } catch (_) {
      logo = null; // si falla, seguimos sin logo
    }

    doc.addPage(
      pw.Page(
        pageFormat: await _preferredPdfFormat(),
        margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) ...[
                pw.Center(child: pw.Image(logo, height: 24)),
                pw.SizedBox(height: 6),
              ],
              pw.Text('========================================',
                  style: s(true)),
              pw.Text('              CIERRE DE CAJA              ',
                  style: s(true)),
              pw.Text('========================================',
                  style: s(true)),
              pw.SizedBox(height: 6),
              pw.Text(line('', codigoCaja), style: s()),
              if (pvLabel != null && pvLabel.trim().isNotEmpty)
                pw.Text(line('PV:', pvLabel.trim()), style: s()),
              if ((c['estado'] as String?) != null)
                pw.Text(line('Estado:', c['estado']?.toString()), style: s()),
              pw.Text(
                  line('Fecha apertura:',
                      '${c['fecha'] ?? ''} ${c['hora_apertura'] ?? ''}'),
                  style: s()),
              pw.Text(
                  line('Cajero apertura:', c['cajero_apertura']?.toString()),
                  style: s()),
              pw.Text(line('Unidad de gestión:', c['disciplina']?.toString()),
                  style: s()),
              if (descripcionEvento.isNotEmpty)
                pw.Text(line('Descripción del evento:', descripcionEvento),
                    style: s()),
              if ((c['cierre_dt'] as String?) != null)
                pw.Text(line('Fecha cierre:', c['cierre_dt']?.toString()),
                    style: s()),
              if ((c['cajero_cierre'] as String?) != null &&
                  (c['cajero_cierre'] as String).isNotEmpty)
                pw.Text(
                    line('Cajero de cierre:', c['cajero_cierre']?.toString()),
                    style: s()),
              if (obsApertura.isNotEmpty)
                pw.Text('Obs. apertura: $obsApertura', style: s()),
              if (obsCierre.isNotEmpty)
                pw.Text('Obs. cierre: $obsCierre', style: s()),
              pw.SizedBox(height: 6),
              // --- FONDO INICIAL ---
              pw.Text('FONDO INICIAL', style: s(true)),
              pw.Text('Saldo inicial de caja: ${_formatCurrency(fondo)}',
                  style: s()),
              pw.SizedBox(height: 6),
              // --- RESUMEN DE VENTAS ---
              pw.Text('RESUMEN DE VENTAS', style: s(true)),
              pw.SizedBox(height: 4),
              ...totalesMp.map((m) => pw.Text(
                    '${(m['mp_desc'] as String?) ?? 'MP ${m['mp']}'}: ${_formatCurrency(((m['total'] as num?) ?? 0).toDouble())}',
                    style: s(),
                  )),
              pw.SizedBox(height: 4),
              pw.Text(
                  'TOTAL VENDIDO: ${_formatCurrency(((resumen['total'] as num?) ?? 0).toDouble())}',
                  style: s(true).copyWith(fontSize: 10)),
              pw.SizedBox(height: 8),
              // --- MOVIMIENTOS DE CAJA ---
              () {
                final ingTotal = movIngEfec + movIngTransf;
                final retTotal = movRetEfec + movRetTransf;
                // Ventas en efectivo
                double ventasEfec = 0;
                for (final m in totalesMp) {
                  final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
                  if (desc.contains('efectivo')) {
                    ventasEfec += ((m['total'] as num?) ?? 0).toDouble();
                  }
                }
                final totalMovEfectivo = ventasEfec + movIngEfec - movRetEfec;

                // Helper para formatear timestamp
                String fmtTs(Map<String, Object?> m) {
                  final ts = (m['created_ts'] as num?)?.toInt();
                  if (ts == null) return '';
                  final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                  final dd = dt.day.toString().padLeft(2, '0');
                  final mm = dt.month.toString().padLeft(2, '0');
                  final hh = dt.hour.toString().padLeft(2, '0');
                  final mi = dt.minute.toString().padLeft(2, '0');
                  return '$dd/$mm $hh:$mi';
                }

                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('MOVIMIENTOS DE CAJA', style: s(true)),
                    pw.SizedBox(height: 4),
                    pw.Text('+ Ingresos extra: ${_formatCurrency(ingTotal)}',
                        style: s()),
                    if (movIngEfec > 0)
                      pw.Text('    Efectivo: ${_formatCurrency(movIngEfec)}', style: s()),
                    if (movIngTransf > 0)
                      pw.Text('    Transferencia: ${_formatCurrency(movIngTransf)}', style: s()),
                    // Detalle de ingresos
                    ...movimientos
                        .where((m) => (m['tipo'] ?? '').toString().toUpperCase() == 'INGRESO')
                        .map((m) {
                      final monto = ((m['monto'] as num?) ?? 0).toDouble();
                      final obs = (m['observacion'] as String?)?.trim();
                      final obsPart = (obs != null && obs.isNotEmpty) ? ' $obs' : '';
                      final mpDesc = (m['medio_pago_desc'] as String?) ?? 'Efectivo';
                      return pw.Text(
                        '  * ${fmtTs(m)} Ingreso: ${_formatCurrency(monto)} ($mpDesc)$obsPart',
                        style: s(),
                      );
                    }),
                    pw.Text('- Retiros: ${_formatCurrency(retTotal)}',
                        style: s()),
                    if (movRetEfec > 0)
                      pw.Text('    Efectivo: ${_formatCurrency(movRetEfec)}', style: s()),
                    if (movRetTransf > 0)
                      pw.Text('    Transferencia: ${_formatCurrency(movRetTransf)}', style: s()),
                    // Detalle de retiros
                    ...movimientos
                        .where((m) => (m['tipo'] ?? '').toString().toUpperCase() == 'RETIRO')
                        .map((m) {
                      final monto = ((m['monto'] as num?) ?? 0).toDouble();
                      final obs = (m['observacion'] as String?)?.trim();
                      final obsPart = (obs != null && obs.isNotEmpty) ? ' $obs' : '';
                      final mpDesc = (m['medio_pago_desc'] as String?) ?? 'Efectivo';
                      return pw.Text(
                        '  * ${fmtTs(m)} Retiro: ${_formatCurrency(monto)} ($mpDesc)$obsPart',
                        style: s(),
                      );
                    }),
                    pw.SizedBox(height: 4),
                    pw.Text(
                        'TOTAL MOV. EFECTIVO DEL DIA: ${totalMovEfectivo >= 0 ? '+' : ''}${_formatCurrency(totalMovEfectivo)}',
                        style: s(true)),
                    pw.Text(
                        '(${_formatCurrency(ventasEfec)} + ${_formatCurrency(movIngEfec)} - ${_formatCurrency(movRetEfec)})',
                        style: s()),
                  ],
                );
              }(),
              pw.SizedBox(height: 8),
              // --- CONCILIACIÓN POR MEDIO DE PAGO ---
              () {
                double ventasEfec = 0;
                double ventasTransf = 0;
                for (final m in totalesMp) {
                  final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
                  if (desc.contains('efectivo')) {
                    ventasEfec += ((m['total'] as num?) ?? 0).toDouble();
                  }
                  if (desc.contains('transfer')) {
                    ventasTransf += ((m['total'] as num?) ?? 0).toDouble();
                  }
                }
                final efectivoEsperado = fondo + ventasEfec + movIngEfec - movRetEfec;
                final difEfectivo = efectivoDeclarado - efectivoEsperado;
                final transfEsperadas = ventasTransf + movIngTransf - movRetTransf;
                final difTransf = transferenciasDeclaradasPdf - transfEsperadas;
                final difTotal = difEfectivo + difTransf;
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('CONCILIACIÓN POR MEDIO DE PAGO', style: s(true)),
                    pw.SizedBox(height: 4),
                    pw.Text('EFECTIVO', style: s(true)),
                    pw.Text('Efectivo esperado: ${_formatCurrency(efectivoEsperado)}', style: s()),
                    pw.Text(
                        '(Fondo ${_formatCurrency(fondo)} + Ventas ${_formatCurrency(ventasEfec)} + Ing. ${_formatCurrency(movIngEfec)} - Ret. ${_formatCurrency(movRetEfec)})',
                        style: s()),
                    pw.Text('Efectivo declarado: ${_formatCurrency(efectivoDeclarado)}', style: s()),
                    pw.Text('Diferencia efectivo: ${difEfectivo >= 0 ? '+' : ''}${_formatCurrency(difEfectivo)}',
                        style: s(true)),
                    pw.SizedBox(height: 4),
                    pw.Text('TRANSFERENCIAS', style: s(true)),
                    pw.Text('Transf. esperadas: ${_formatCurrency(transfEsperadas)}', style: s()),
                    pw.Text(
                        '(Ventas ${_formatCurrency(ventasTransf)} + Ing. ${_formatCurrency(movIngTransf)} - Ret. ${_formatCurrency(movRetTransf)})',
                        style: s()),
                    pw.Text('Transf. declaradas: ${_formatCurrency(transferenciasDeclaradasPdf)}', style: s()),
                    pw.Text('Diferencia transf.: ${difTransf >= 0 ? '+' : ''}${_formatCurrency(difTransf)}',
                        style: s(true)),
                    pw.SizedBox(height: 4),
                    pw.Text('DIFERENCIA TOTAL DEL EVENTO', style: s(true)),
                    pw.Text('${difTotal >= 0 ? '+' : ''}${_formatCurrency(difTotal)}',
                        style: s(true).copyWith(fontSize: 10)),
                    pw.Text('(Suma de diferencias por medio de pago)', style: s()),
                  ],
                );
              }(),
              pw.SizedBox(height: 8),
              // --- RESULTADO ECONÓMICO DEL EVENTO ---
              () {
                final ingTotal = movIngEfec + movIngTransf;
                final retTotal = movRetEfec + movRetTransf;
                double vEfec = 0, vTransf = 0;
                for (final m in totalesMp) {
                  final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
                  if (desc.contains('efectivo')) vEfec += ((m['total'] as num?) ?? 0).toDouble();
                  if (desc.contains('transfer')) vTransf += ((m['total'] as num?) ?? 0).toDouble();
                }
                final resultadoNeto = vEfec + vTransf + ingTotal - retTotal - fondo;
                // Diferencias por medio de pago
                final cajaEsperadaPdf = fondo + vEfec + movIngEfec - movRetEfec;
                final difEfPdf = efectivoDeclarado - cajaEsperadaPdf;
                final transfEsperadasPdf = vTransf + movIngTransf - movRetTransf;
                final difTrPdf = transferenciasDeclaradasPdf - transfEsperadasPdf;
                final resultadoConDif = resultadoNeto + difEfPdf + difTrPdf;
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('RESULTADO ECONÓMICO DEL EVENTO', style: s(true)),
                    pw.SizedBox(height: 4),
                    pw.Text('Ventas en efectivo:       ${_formatCurrency(vEfec)}', style: s()),
                    pw.Text('Ventas por transferencia: ${_formatCurrency(vTransf)}', style: s()),
                    pw.Text('Otros ingresos efec.:     ${_formatCurrency(movIngEfec)}', style: s()),
                    pw.Text('Otros ingresos transf.:   ${_formatCurrency(movIngTransf)}', style: s()),
                    pw.Text('Retiros efec.:           (${_formatCurrency(movRetEfec)})', style: s()),
                    pw.Text('Retiros transf.:         (${_formatCurrency(movRetTransf)})', style: s()),
                    pw.Text('Saldo inicial caja:      (${_formatCurrency(fondo)})', style: s()),
                    pw.SizedBox(height: 2),
                    pw.Text('RESULTADO NETO: ${_formatCurrency(resultadoNeto)}',
                        style: s(true).copyWith(fontSize: 10)),
                    pw.Text(
                        '(${_formatCurrency(vEfec)} + ${_formatCurrency(vTransf)} + ${_formatCurrency(ingTotal)} - ${_formatCurrency(retTotal)} - ${_formatCurrency(fondo)})',
                        style: s()),
                    pw.SizedBox(height: 6),
                    pw.Text('RESULTADO NETO + DIFERENCIAS', style: s(true)),
                    pw.SizedBox(height: 2),
                    pw.Text('Dif. efectivo: ${difEfPdf >= 0 ? '+' : ''}${_formatCurrency(difEfPdf)}', style: s()),
                    pw.Text('Dif. transferencias: ${difTrPdf >= 0 ? '+' : ''}${_formatCurrency(difTrPdf)}', style: s()),
                    pw.SizedBox(height: 2),
                    pw.Text('TOTAL: ${_formatCurrency(resultadoConDif)}',
                        style: s(true).copyWith(fontSize: 10)),
                    pw.Text(
                        '(${_formatCurrency(resultadoNeto)} + ${_formatCurrency(difEfPdf)} + ${_formatCurrency(difTrPdf)})',
                        style: s()),
                  ],
                );
              }(),
              pw.SizedBox(height: 6),
              pw.Text(
                  'Entradas vendidas: ${entradasVendidas == null ? '-' : entradasVendidas}',
                  style: s()),
              pw.Text(
                  'Tickets vendidos: ${(resumen['tickets']['emitidos'] ?? 0)}',
                  style: s()),
              pw.Text(
                  'Tickets anulados: ${(resumen['tickets']['anulados'] ?? 0)}',
                  style: s()),
              pw.SizedBox(height: 6),
              pw.Text('ITEMS VENDIDOS:', style: s(true)),
              pw.SizedBox(height: 2),
              ...porProd.map((p) => pw.Text(
                    '${(p['nombre'] ?? '')} x ${(p['cantidad'] ?? 0)} = ${_formatCurrency(((p['total'] as num?) ?? 0).toDouble())}',
                    style: s(),
                  )),
              if (obsPostCierre.isNotEmpty) ...[  
                pw.SizedBox(height: 6),
                pw.Text('OBS. POST-CIERRE:', style: s(true)),
                if (obsPostCierreTs.isNotEmpty)
                  pw.Text('Fecha: $obsPostCierreTs', style: s()),
                pw.Text(obsPostCierre, style: s()),
              ],
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  /// Construye el PDF de un evento (fecha + disciplina) a partir de una lista de cajas.
  ///
  /// - `detallePorCaja=true`: una sección por caja (similar al cierre de caja).
  /// - `detallePorCaja=false`: un reporte global sumarizado (totales + listados agregados).
  Future<Uint8List> buildEventoPdf({
    required String fecha,
    required String disciplina,
    required List<int> cajaIds,
    required bool detallePorCaja,
  }) async {
    final db = await AppDatabase.instance();

    if (cajaIds.isEmpty) {
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          pageFormat: await _preferredPdfFormat(),
          margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          build: (_) => pw.Center(
            child: pw.Text('Sin cajas para el evento $disciplina - $fecha'),
          ),
        ),
      );
      return doc.save();
    }

    final placeholders = List.filled(cajaIds.length, '?').join(',');
    final cajas = await db.rawQuery('''
      SELECT id, codigo_caja, disciplina, fecha, estado,
             fondo_inicial, conteo_efectivo_final, conteo_transferencias_final,
             diferencia, entradas, hora_apertura, hora_cierre, cajero_apertura,
             cajero_cierre, descripcion_evento, observaciones_apertura, obs_cierre,
             apertura_dt, cierre_dt
      FROM caja_diaria
      WHERE id IN ($placeholders)
      ORDER BY apertura_dt ASC, id ASC
    ''', cajaIds);

    final resumen = await CajaService().resumenCajas(cajaIds);
    final movimientos = await db.rawQuery('''
      SELECT caja_id, tipo, monto, observacion, created_ts
      FROM caja_movimiento
      WHERE caja_id IN ($placeholders)
      ORDER BY created_ts ASC
    ''', cajaIds);

    final totalesMp = (resumen['por_mp'] as List).cast<Map<String, Object?>>();
    final porProd =
        (resumen['por_producto'] as List).cast<Map<String, Object?>>();

    double sumFondo = 0;
    double sumEfecDeclarado = 0;
    double sumDiferencia = 0;
    int sumEntradas = 0;
    bool anyEntradas = false;

    final codigosCajas = <String>[];
    final pvs = <String>{};

    for (final c in cajas) {
      sumFondo += ((c['fondo_inicial'] as num?) ?? 0).toDouble();
      sumEfecDeclarado +=
          ((c['conteo_efectivo_final'] as num?) ?? 0).toDouble();
      sumDiferencia += ((c['diferencia'] as num?) ?? 0).toDouble();
      final entradas = (c['entradas'] as num?)?.toInt();
      if (entradas != null) {
        anyEntradas = true;
        sumEntradas += entradas;
      }

      final codigo = (c['codigo_caja'] ?? '').toString().trim();
      if (codigo.isNotEmpty) {
        codigosCajas.add(codigo);
        final pvLabel = await _buildPvLabelFromCajaCodigo(codigo);
        if (pvLabel != null && pvLabel.trim().isNotEmpty) {
          pvs.add(pvLabel.trim());
        }
      }
    }

    double sumIng = 0;
    double sumRet = 0;
    for (final m in movimientos) {
      final tipo = (m['tipo'] ?? '').toString().toUpperCase();
      final monto = ((m['monto'] as num?) ?? 0).toDouble();
      if (tipo == 'INGRESO') {
        sumIng += monto;
      } else if (tipo == 'RETIRO') {
        sumRet += monto;
      }
    }

    pw.ImageProvider? logo;
    try {
      logo = await imageFromAssetBundle('assets/icons/app_icon_foreground.png');
    } catch (_) {
      logo = null;
    }

    pw.TextStyle s([bool b = false]) => pw.TextStyle(
        fontSize: 9, fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal);

    final doc = pw.Document();

    if (detallePorCaja) {
      // Precalcular por caja (MultiPage.build no puede ser async).
      final detalles = <Map<String, dynamic>>[];
      for (final c in cajas) {
        final cajaId = (c['id'] as num?)?.toInt();
        if (cajaId == null) continue;

        final resumenCaja = await CajaService().resumenCaja(cajaId);
        final movCaja = await db.query('caja_movimiento',
            where: 'caja_id=?', whereArgs: [cajaId], orderBy: 'created_ts ASC');

        final codigoCaja = (c['codigo_caja'] ?? '').toString();
        final pvLabel = codigoCaja.trim().isNotEmpty
            ? await _buildPvLabelFromCajaCodigo(codigoCaja)
            : null;

        detalles.add({
          'caja': c,
          'cajaId': cajaId,
          'resumen': resumenCaja,
          'movimientos': movCaja,
          'pvLabel': pvLabel,
        });
      }

      // 1 caja por página
      for (final d in detalles) {
        final c = (d['caja'] as Map).cast<String, Object?>();
        final resumenCaja = (d['resumen'] as Map<String, dynamic>);
        final movCaja = (d['movimientos'] as List).cast<Map<String, Object?>>();
        final pvLabel = d['pvLabel'] as String?;

        final codigoCaja = (c['codigo_caja'] ?? '').toString();
        final fondo = ((c['fondo_inicial'] as num?) ?? 0).toDouble();
        final efectivoDeclarado =
            ((c['conteo_efectivo_final'] as num?) ?? 0).toDouble();
        final transferenciasDeclaradasEvt =
            ((c['conteo_transferencias_final'] as num?) ?? 0).toDouble();
        final diferencia = ((c['diferencia'] as num?) ?? 0).toDouble();
        final int? entradasVendidas = (c['entradas'] as num?)?.toInt();
        final descEvento = (c['descripcion_evento'] as String?) ?? '';
        final obsA = (c['observaciones_apertura'] as String?) ?? '';
        final obsC = (c['obs_cierre'] as String?) ?? '';

        final totalesMpCaja =
            (resumenCaja['por_mp'] as List).cast<Map<String, Object?>>();
        final porProdCaja =
            (resumenCaja['por_producto'] as List).cast<Map<String, Object?>>();
        final ticketsCaja = (resumenCaja['tickets'] as Map?) ?? const {};

        // Paginación (aproximada por cantidad de filas).
        // Objetivo: evitar desbordes cuando hay muchos items/movimientos.
        const int maxItemsFirstPage = 18;
        const int maxMovsFirstPage = 14;
        const int maxItemsNextPage = 30;
        const int maxMovsNextPage = 26;

        List<List<Map<String, Object?>>> chunkList(
          List<Map<String, Object?>> src,
          int chunkSize,
        ) {
          if (src.isEmpty) return const [];
          final out = <List<Map<String, Object?>>>[];
          for (int i = 0; i < src.length; i += chunkSize) {
            out.add(src.sublist(
                i, i + chunkSize > src.length ? src.length : i + chunkSize));
          }
          return out;
        }

        final itemChunksFirst = chunkList(porProdCaja, maxItemsFirstPage);
        final movChunksFirst = chunkList(movCaja, maxMovsFirstPage);

        // Para las páginas de continuación usamos tamaños más grandes.
        final itemRemain = porProdCaja.length > maxItemsFirstPage
            ? porProdCaja.sublist(maxItemsFirstPage)
            : <Map<String, Object?>>[];
        final movRemain = movCaja.length > maxMovsFirstPage
            ? movCaja.sublist(maxMovsFirstPage)
            : <Map<String, Object?>>[];
        final itemChunksNext = chunkList(itemRemain, maxItemsNextPage);
        final movChunksNext = chunkList(movRemain, maxMovsNextPage);

        final firstItems = itemChunksFirst.isNotEmpty
            ? itemChunksFirst.first
            : const <Map<String, Object?>>[];
        final firstMovs = movChunksFirst.isNotEmpty
            ? movChunksFirst.first
            : const <Map<String, Object?>>[];

        final continuationPages = (itemChunksNext.length > movChunksNext.length)
            ? itemChunksNext.length
            : movChunksNext.length;
        final totalPages = 1 + continuationPages;

        double ing = 0;
        double ret = 0;
        for (final m in movCaja) {
          final tipo = (m['tipo'] ?? '').toString().toUpperCase();
          final monto = ((m['monto'] as num?) ?? 0).toDouble();
          if (tipo == 'INGRESO') {
            ing += monto;
          } else if (tipo == 'RETIRO') {
            ret += monto;
          }
        }

        doc.addPage(
          pw.Page(
            pageFormat: await _preferredPdfFormat(),
            margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            build: (_) {
              final widgets = <pw.Widget>[];
              if (logo != null) {
                widgets.add(pw.Center(child: pw.Image(logo, height: 24)));
                widgets.add(pw.SizedBox(height: 6));
              }

              widgets.add(pw.Text('========================================',
                  style: s(true)));
              widgets.add(pw.Text('             REPORTE DEL EVENTO          ',
                  style: s(true)));
              widgets.add(pw.Text('========================================',
                  style: s(true)));
              widgets.add(pw.SizedBox(height: 6));

              widgets.add(pw.Text(
                'Caja: ${codigoCaja.isEmpty ? '(sin código)' : codigoCaja}  —  Página 1/$totalPages',
                style: s(true),
              ));
              widgets.add(pw.SizedBox(height: 4));

              widgets.add(pw.Text('Unidad de gestión: $disciplina', style: s()));
              widgets.add(pw.Text('Fecha: $fecha', style: s()));
              if (pvs.isNotEmpty) {
                widgets.add(pw.Text('PV(s): ${pvs.join(' · ')}', style: s()));
              }
              widgets.add(pw.SizedBox(height: 6));

              widgets.add(pw.Text('CIERRE DE CAJA', style: s(true)));
              widgets.add(pw.Text(codigoCaja, style: s(true)));
              if (pvLabel != null && pvLabel.trim().isNotEmpty) {
                widgets.add(pw.Text('PV: ${pvLabel.trim()}', style: s()));
              }
              widgets.add(pw.Text(
                  'Apertura: ${(c['fecha'] ?? '')} ${(c['hora_apertura'] ?? '')}',
                  style: s()));
              if ((c['cierre_dt'] as String?) != null) {
                widgets.add(pw.Text('Cierre: ${c['cierre_dt']}', style: s()));
              }
              if ((c['cajero_apertura'] as String?) != null) {
                widgets.add(pw.Text('Cajero apertura: ${c['cajero_apertura']}',
                    style: s()));
              }
              if ((c['cajero_cierre'] as String?) != null &&
                  (c['cajero_cierre'] as String).isNotEmpty) {
                widgets.add(pw.Text('Cajero cierre: ${c['cajero_cierre']}',
                    style: s()));
              }
              if (descEvento.trim().isNotEmpty) {
                widgets.add(pw.Text('Evento: $descEvento', style: s()));
              }
              if (obsA.trim().isNotEmpty) {
                widgets.add(pw.Text('Obs. apertura: $obsA', style: s()));
              }
              if (obsC.trim().isNotEmpty) {
                widgets.add(pw.Text('Obs. cierre: $obsC', style: s()));
              }
              widgets.add(pw.SizedBox(height: 6));

              widgets.add(pw.Text('TOTALES POR MEDIO DE PAGO', style: s(true)));
              widgets.add(pw.SizedBox(height: 2));
              widgets.addAll(totalesMpCaja.map((m) => pw.Text(
                    '${(m['mp_desc'] as String?) ?? 'MP ${m['mp']}'}: ${_formatCurrency(((m['total'] as num?) ?? 0).toDouble())}',
                    style: s(),
                  )));
              widgets.add(pw.Text(
                  'TOTAL: ${_formatCurrency(((resumenCaja['total'] as num?) ?? 0).toDouble())}',
                  style: s(true).copyWith(fontSize: 12)));

              widgets.add(pw.SizedBox(height: 6));
              // --- CONCILIACIÓN POR MEDIO DE PAGO ---
              double ventasEfecEvt = 0;
              double ventasTransfEvt = 0;
              for (final m in totalesMpCaja) {
                final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
                if (desc.contains('efectivo')) {
                  ventasEfecEvt += ((m['total'] as num?) ?? 0).toDouble();
                }
                if (desc.contains('transfer')) {
                  ventasTransfEvt += ((m['total'] as num?) ?? 0).toDouble();
                }
              }
              final efectivoEsperadoEvt = fondo + ventasEfecEvt + ing - ret;
              final difEfectivoEvt = efectivoDeclarado - efectivoEsperadoEvt;
              final transfEsperadasEvt = ventasTransfEvt;
              final difTransfEvt = transferenciasDeclaradasEvt - transfEsperadasEvt;
              final difTotalEvt = difEfectivoEvt + difTransfEvt;
              widgets.add(pw.Text('CONCILIACIÓN POR MEDIO DE PAGO', style: s(true)));
              widgets.add(pw.SizedBox(height: 2));
              widgets.add(pw.Text('EFECTIVO', style: s(true)));
              widgets.add(pw.Text('Efectivo esperado: ${_formatCurrency(efectivoEsperadoEvt)}', style: s()));
              widgets.add(pw.Text('Efectivo declarado: ${_formatCurrency(efectivoDeclarado)}', style: s()));
              widgets.add(pw.Text('Diferencia efectivo: ${difEfectivoEvt >= 0 ? '+' : ''}${_formatCurrency(difEfectivoEvt)}', style: s(true)));
              widgets.add(pw.SizedBox(height: 2));
              widgets.add(pw.Text('TRANSFERENCIAS', style: s(true)));
              widgets.add(pw.Text('Transf. esperadas: ${_formatCurrency(transfEsperadasEvt)}', style: s()));
              widgets.add(pw.Text('Transf. declaradas: ${_formatCurrency(transferenciasDeclaradasEvt)}', style: s()));
              widgets.add(pw.Text('Diferencia transf.: ${difTransfEvt >= 0 ? '+' : ''}${_formatCurrency(difTransfEvt)}', style: s(true)));
              widgets.add(pw.SizedBox(height: 2));
              widgets.add(pw.Text('DIFERENCIA TOTAL DEL EVENTO', style: s(true)));
              widgets.add(pw.Text('${difTotalEvt >= 0 ? '+' : ''}${_formatCurrency(difTotalEvt)}', style: s(true).copyWith(fontSize: 10)));
              widgets.add(pw.Text('(Suma de diferencias por medio de pago)', style: s()));
              widgets.add(pw.SizedBox(height: 4));
              widgets.add(pw.Text(
                  'Entradas vendidas: ${entradasVendidas == null ? '-' : entradasVendidas}',
                  style: s()));
              widgets.add(pw.Text(
                  'Tickets vendidos: ${ticketsCaja['emitidos'] ?? 0}',
                  style: s()));
              widgets.add(pw.Text(
                  'Tickets anulados: ${ticketsCaja['anulados'] ?? 0}',
                  style: s()));

              widgets.add(pw.SizedBox(height: 6));
              widgets.add(pw.Text('ITEMS VENDIDOS:', style: s(true)));
              widgets.add(pw.SizedBox(height: 2));
              widgets.addAll(firstItems.map((p) => pw.Text(
                    '(${(p['nombre'] ?? '')} x ${(p['cantidad'] ?? 0)}) = ${_formatCurrency(((p['total'] as num?) ?? 0).toDouble())}',
                    style: s(),
                  )));

              final itemsLeft = porProdCaja.length - firstItems.length;
              if (itemsLeft > 0) {
                widgets.add(pw.SizedBox(height: 2));
                widgets.add(pw.Text(
                    '(+${itemsLeft} ítem(s) en páginas siguientes)',
                    style: s()));
              }

              if (firstMovs.isNotEmpty) {
                widgets.add(pw.SizedBox(height: 6));
                widgets.add(pw.Text('MOVIMIENTOS:', style: s(true)));
                widgets.add(pw.SizedBox(height: 2));
                for (final m in firstMovs) {
                  final ts = (m['created_ts'] as num?)?.toInt();
                  String tsStr = '';
                  if (ts != null) {
                    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                    final dd = dt.day.toString().padLeft(2, '0');
                    final mm = dt.month.toString().padLeft(2, '0');
                    final hh = dt.hour.toString().padLeft(2, '0');
                    final mi = dt.minute.toString().padLeft(2, '0');
                    tsStr = '$dd/$mm $hh:$mi';
                  }
                  final tipo = (m['tipo'] ?? '').toString();
                  final monto = ((m['monto'] as num?) ?? 0).toDouble();
                  final obs = (m['observacion'] as String?)?.trim();
                  final obsPart =
                      (obs != null && obs.isNotEmpty) ? ' - $obs' : '';
                  widgets.add(pw.Text(
                    '$tsStr $tipo: ${_formatCurrency(monto)}$obsPart',
                    style: s(),
                  ));
                }

                final movLeft = movCaja.length - firstMovs.length;
                if (movLeft > 0) {
                  widgets.add(pw.SizedBox(height: 2));
                  widgets.add(pw.Text(
                      '(+${movLeft} movimiento(s) en páginas siguientes)',
                      style: s()));
                }
              }

              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: widgets,
              );
            },
          ),
        );

        // Páginas de continuación (si hay remanentes)
        for (int page = 0; page < continuationPages; page++) {
          final itemsChunk = page < itemChunksNext.length
              ? itemChunksNext[page]
              : const <Map<String, Object?>>[];
          final movChunk = page < movChunksNext.length
              ? movChunksNext[page]
              : const <Map<String, Object?>>[];
          if (itemsChunk.isEmpty && movChunk.isEmpty) continue;

          final pageNo = page + 2;
          doc.addPage(
            pw.Page(
              pageFormat: await _preferredPdfFormat(),
              margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              build: (_) {
                final widgets = <pw.Widget>[];

                if (logo != null) {
                  widgets.add(pw.Center(child: pw.Image(logo, height: 24)));
                  widgets.add(pw.SizedBox(height: 6));
                }
                widgets.add(pw.Text('========================================',
                    style: s(true)));
                widgets.add(pw.Text('             REPORTE DEL EVENTO          ',
                    style: s(true)));
                widgets.add(pw.Text('========================================',
                    style: s(true)));
                widgets.add(pw.SizedBox(height: 6));

                widgets.add(pw.Text('Unidad de gestión: $disciplina', style: s()));
                widgets.add(pw.Text('Fecha: $fecha', style: s()));
                widgets.add(pw.SizedBox(height: 6));

                widgets.add(pw.Text(
                  'Caja: ${codigoCaja.isEmpty ? '(sin código)' : codigoCaja}  —  Página $pageNo/$totalPages',
                  style: s(true),
                ));
                widgets.add(pw.Text('Continuación', style: s()));
                widgets.add(pw.SizedBox(height: 6));

                if (itemsChunk.isNotEmpty) {
                  widgets
                      .add(pw.Text('ITEMS VENDIDOS (CONT.):', style: s(true)));
                  widgets.add(pw.SizedBox(height: 2));
                  widgets.addAll(itemsChunk.map((p) => pw.Text(
                        '(${(p['nombre'] ?? '')} x ${(p['cantidad'] ?? 0)}) = ${_formatCurrency(((p['total'] as num?) ?? 0).toDouble())}',
                        style: s(),
                      )));
                  widgets.add(pw.SizedBox(height: 8));
                }

                if (movChunk.isNotEmpty) {
                  widgets.add(pw.Text('MOVIMIENTOS (CONT.):', style: s(true)));
                  widgets.add(pw.SizedBox(height: 2));
                  for (final m in movChunk) {
                    final ts = (m['created_ts'] as num?)?.toInt();
                    String tsStr = '';
                    if (ts != null) {
                      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                      final dd = dt.day.toString().padLeft(2, '0');
                      final mm = dt.month.toString().padLeft(2, '0');
                      final hh = dt.hour.toString().padLeft(2, '0');
                      final mi = dt.minute.toString().padLeft(2, '0');
                      tsStr = '$dd/$mm $hh:$mi';
                    }
                    final tipo = (m['tipo'] ?? '').toString();
                    final monto = ((m['monto'] as num?) ?? 0).toDouble();
                    final obs = (m['observacion'] as String?)?.trim();
                    final obsPart =
                        (obs != null && obs.isNotEmpty) ? ' - $obs' : '';
                    widgets.add(pw.Text(
                      '$tsStr $tipo: ${_formatCurrency(monto)}$obsPart',
                      style: s(),
                    ));
                  }
                }

                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: widgets,
                );
              },
            ),
          );
        }
      }

      return doc.save();
    }

    // === Sumarizado ===
    doc.addPage(
      pw.Page(
        pageFormat: await _preferredPdfFormat(),
        margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        build: (_) {
          final widgets = <pw.Widget>[];
          if (logo != null) {
            widgets.add(pw.Center(child: pw.Image(logo, height: 24)));
            widgets.add(pw.SizedBox(height: 6));
          }
          widgets.add(pw.Text('========================================',
              style: s(true)));
          widgets.add(pw.Text('             REPORTE DEL EVENTO          ',
              style: s(true)));
          widgets.add(pw.Text('========================================',
              style: s(true)));
          widgets.add(pw.SizedBox(height: 6));

          widgets.add(pw.Text('Unidad de gestión: $disciplina', style: s()));
          widgets.add(pw.Text('Fecha: $fecha', style: s()));
          if (pvs.isNotEmpty) {
            widgets.add(pw.Text('PV(s): ${pvs.join(' · ')}', style: s()));
          }
          if (codigosCajas.isNotEmpty) {
            widgets
                .add(pw.Text('Cajas: ${codigosCajas.join(' · ')}', style: s()));
          }

          widgets.add(pw.SizedBox(height: 8));
          widgets.add(pw.Text('TOTALES POR MEDIO DE PAGO', style: s(true)));
          widgets.add(pw.SizedBox(height: 2));
          widgets.addAll(totalesMp.map((m) => pw.Text(
                '${(m['mp_desc'] as String?) ?? 'MP ${m['mp']}'}: ${_formatCurrency(((m['total'] as num?) ?? 0).toDouble())}',
                style: s(),
              )));

          widgets.add(pw.SizedBox(height: 4));
          widgets.add(pw.Text(
              'TOTAL: ${_formatCurrency(((resumen['total'] as num?) ?? 0).toDouble())}',
              style: s(true).copyWith(fontSize: 12)));

          widgets.add(pw.SizedBox(height: 6));
          widgets.add(pw.Text(
              'Fondo inicial (suma): ${_formatCurrency(sumFondo)}',
              style: s()));
          widgets.add(pw.Text(
              'Efectivo declarado (suma): ${_formatCurrency(sumEfecDeclarado)}',
              style: s()));
          widgets.add(pw.Text(
              'Ingresos registrados: ${_formatCurrency(sumIng)}',
              style: s()));
          widgets.add(pw.Text('Retiros registrados: ${_formatCurrency(sumRet)}',
              style: s()));
          widgets.add(pw.Text(
              'Diferencia (suma): ${_formatCurrency(sumDiferencia)}',
              style: s(true)));
          widgets.add(pw.Text(
              'Entradas vendidas (suma): ${anyEntradas ? sumEntradas : '-'}',
              style: s()));

          final tickets = (resumen['tickets'] as Map?) ?? const {};
          widgets.add(pw.Text('Tickets vendidos: ${tickets['emitidos'] ?? 0}',
              style: s()));
          widgets.add(pw.Text('Tickets anulados: ${tickets['anulados'] ?? 0}',
              style: s()));

          if (movimientos.isNotEmpty) {
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(pw.Text('MOVIMIENTOS (GLOBAL):', style: s(true)));
            widgets.add(pw.SizedBox(height: 2));
            for (final m in movimientos) {
              final cajaId = (m['caja_id'] as num?)?.toInt();
              String codigoCaja = '';
              if (cajaId != null) {
                final found = cajas
                    .where((c) => (c['id'] as num?)?.toInt() == cajaId)
                    .toList();
                if (found.isNotEmpty) {
                  codigoCaja = (found.first['codigo_caja'] ?? '').toString();
                }
              }

              final pvCodigo = CajaService.puntoVentaFromCodigoCaja(codigoCaja);

              final ts = (m['created_ts'] as num?)?.toInt();
              String tsStr = '';
              if (ts != null) {
                final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                final dd = dt.day.toString().padLeft(2, '0');
                final mm = dt.month.toString().padLeft(2, '0');
                final hh = dt.hour.toString().padLeft(2, '0');
                final mi = dt.minute.toString().padLeft(2, '0');
                tsStr = '$dd/$mm $hh:$mi';
              }
              final tipo = (m['tipo'] ?? '').toString();
              final monto = ((m['monto'] as num?) ?? 0).toDouble();
              final obs = (m['observacion'] as String?)?.trim();
              final obsPart = (obs != null && obs.isNotEmpty) ? ' - $obs' : '';
              final cajaPart = (pvCodigo != null && pvCodigo.trim().isNotEmpty)
                  ? '[${pvCodigo.trim()}] '
                  : '';
              widgets.add(pw.Text(
                '$tsStr $cajaPart$tipo: ${_formatCurrency(monto)}$obsPart',
                style: s(),
              ));
            }
          }

          widgets.add(pw.SizedBox(height: 8));
          widgets.add(pw.Text('ITEMS VENDIDOS (GLOBAL):', style: s(true)));
          widgets.add(pw.SizedBox(height: 2));
          widgets.addAll(porProd.map((p) => pw.Text(
                '(${(p['nombre'] ?? '')} x ${(p['cantidad'] ?? 0)}) = ${_formatCurrency(((p['total'] as num?) ?? 0).toDouble())}',
                style: s(),
              )));

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: widgets,
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> printEventoPdf({
    required String fecha,
    required String disciplina,
    required List<int> cajaIds,
    required bool detallePorCaja,
  }) async {
    await Printing.layoutPdf(
      onLayout: (format) async => buildEventoPdf(
        fecha: fecha,
        disciplina: disciplina,
        cajaIds: cajaIds,
        detallePorCaja: detallePorCaja,
      ),
      name: detallePorCaja
          ? 'evento_${fecha}_detalle.pdf'
          : 'evento_${fecha}_sumarizado.pdf',
    );
  }

  Future<void> shareEventoPdf({
    required String fecha,
    required String disciplina,
    required List<int> cajaIds,
    required bool detallePorCaja,
  }) async {
    final bytes = await buildEventoPdf(
      fecha: fecha,
      disciplina: disciplina,
      cajaIds: cajaIds,
      detallePorCaja: detallePorCaja,
    );
    await Printing.sharePdf(
      bytes: bytes,
      filename: detallePorCaja
          ? 'evento_${fecha}_detalle.pdf'
          : 'evento_${fecha}_sumarizado.pdf',
    );
  }

  // ========================= ESC/POS (USB) =========================
  /// Genera y guarda el PDF de cierre de caja en el directorio de documentos de la app.
  /// Devuelve el File guardado.
  Future<File> saveCajaResumenPdfFile(int cajaId) async {
    final db = await AppDatabase.instance();
    String codigo = 'caja_$cajaId';
    try {
      final r = await db.query('caja_diaria',
          columns: ['codigo_caja'],
          where: 'id=?',
          whereArgs: [cajaId],
          limit: 1);
      if (r.isNotEmpty && (r.first['codigo_caja'] as String?) != null) {
        codigo =
            (r.first['codigo_caja'] as String).replaceAll(RegExp(r'\s+'), '_');
      }
    } catch (_) {}
    final bytes = await buildCajaResumenPdf(cajaId);
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final ts =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final filename = 'cierre_${codigo}_$ts.pdf';
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Construye bytes ESC/POS para un ticket de ejemplo (sin tocar la DB)
  Future<Uint8List> buildTicketEscPosSample({int? lineWidth}) async {
    final b = BytesBuilder();
    void init() {
      b.add([0x1B, 0x40]);
    }

    void alignCenter() => b.add([0x1B, 0x61, 0x01]);
    void boldOn() => b.add([0x1B, 0x45, 0x01]);
    void boldOff() => b.add([0x1B, 0x45, 0x00]);
    void sizeNormal() => b.add([0x1D, 0x21, 0x00]);
    void sizeDoubleH() => b.add([0x1D, 0x21, 0x01]);
    void sizeDoubleWH() => b.add([0x1D, 0x21, 0x11]);
    void feed([int n = 1]) => b.add(List<int>.filled(n, 0x0A));
    String clean(String s) {
      const map = {
        'á': 'a',
        'é': 'e',
        'í': 'i',
        'ó': 'o',
        'ú': 'u',
        'Á': 'A',
        'É': 'E',
        'Í': 'I',
        'Ó': 'O',
        'Ú': 'U',
        'ñ': 'n',
        'Ñ': 'N',
        'ü': 'u',
        'Ü': 'U'
      };
      return s.split('').map((c) => map[c] ?? c).join();
    }

    void text(String s) {
      b.add(utf8.encode(clean(s)));
      feed();
    }

    init();
    alignCenter();
    boldOn();
    sizeDoubleH();
    text('Buffet - C.D.M');
    sizeNormal();
    boldOff();
    final now = DateTime.now();
    final dd = now.day.toString().padLeft(2, '0');
    final mm = now.month.toString().padLeft(2, '0');
    final yyyy = now.year.toString();
    final hh = now.hour.toString().padLeft(2, '0');
    final mi = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    text('DEMO-$dd$mm$yyyy-000');
    text('$dd/$mm/$yyyy $hh:$mi:$ss');
    text('DEMO-CAJA');
    feed();
    boldOn();
    sizeDoubleWH();
    text('HAMBURGUESA');
    text(_formatCurrency(1500));
    sizeNormal();
    boldOff();
    feed(1);
    // Corte parcial
    b.add([0x1D, 0x56, 0x42, 0x00]);
    return Uint8List.fromList(b.toBytes());
  }

  /// Imprime solo por USB un ticket de ejemplo (sin generar tickets reales)
  Future<bool> printTicketSampleUsbOnly() async {
    try {
      final bytes = await buildTicketEscPosSample();
      if (bytes.isEmpty) return false;
      return await _usb.printBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  /// Construye bytes ESC/POS para ticket individual (80mm ó 58mm)
  Future<Uint8List> buildTicketEscPos(int ticketId,
      {int lineWidth = 48}) async {
    final db = await AppDatabase.instance();
    final rows = await db.rawQuery('''
      SELECT t.id, t.identificador_ticket, t.fecha_hora, t.total_ticket,
             p.nombre as producto, v.caja_id, c.codigo_caja
      FROM tickets t
      JOIN products p ON p.id = t.producto_id
      JOIN ventas v ON v.id = t.venta_id
      LEFT JOIN caja_diaria c ON c.id = v.caja_id
      WHERE t.id = ?
    ''', [ticketId]);
    if (rows.isEmpty) {
      return Uint8List(0);
    }
    final t = rows.first;
    final identificador =
        (t['identificador_ticket'] as String?) ?? '#${t['id']}';
    final fechaHora = (t['fecha_hora'] as String?) ?? '';
    final cajaCodigo = (t['codigo_caja'] as String?) ?? '-';
    final producto = (t['producto'] as String?) ?? 'Producto';
    final total = ((t['total_ticket'] as num?) ?? 0).toDouble();

    final b = BytesBuilder();
    void init() {
      b.add([0x1B, 0x40]); // init
      // Alineación por defecto izquierda
      b.add([0x1B, 0x61, 0x00]);
    }

    void alignCenter() => b.add([0x1B, 0x61, 0x01]);
    void boldOn() => b.add([0x1B, 0x45, 0x01]);
    void boldOff() => b.add([0x1B, 0x45, 0x00]);
    void sizeNormal() => b.add([0x1D, 0x21, 0x00]);
    // sizeDoubleWH() ya no se usa para reducir el alto del ticket
    void sizeDoubleH() => b.add([0x1D, 0x21, 0x01]);
    void fontA() => b.add([0x1B, 0x4D, 0x00]); // normal
    void fontB() => b.add([0x1B, 0x4D, 0x01]); // un punto más chico
    void feed([int n = 1]) => b.add(List<int>.filled(n, 0x0A));

    String clean(String s) {
      // Reemplazo simple para evitar problemas de codepage
      const map = {
        'á': 'a',
        'é': 'e',
        'í': 'i',
        'ó': 'o',
        'ú': 'u',
        'Á': 'A',
        'É': 'E',
        'Í': 'I',
        'Ó': 'O',
        'Ú': 'U',
        'ñ': 'n',
        'Ñ': 'N',
        'ü': 'u',
        'Ü': 'U'
      };
      return s.split('').map((c) => map[c] ?? c).join();
    }

    void text(String s) {
      b.add(utf8.encode(clean(s)));
      feed();
    }

    init();
    alignCenter();
    boldOn();
    sizeDoubleH();
    text('Buffet - C.D.M');
    sizeNormal();
    boldOff();
    fontB(); // fechas y códigos más chicos
    text(identificador);
    text(fechaHora);
    text(cajaCodigo);
    fontA();
    feed();
    boldOn();
    // tamaño grande como antes para descripción e importe
    b.add([0x1D, 0x21, 0x11]); // sizeDoubleWH
    text(producto.toUpperCase());
    text(_formatCurrency(total));
    sizeNormal();
    boldOff();
    feed(1);
    // Corte parcial
    b.add([0x1D, 0x56, 0x42, 0x00]);

    return Uint8List.fromList(b.toBytes());
  }

  /// Construye bytes ESC/POS de un cierre de caja de ejemplo (sin datos reales)
  Future<Uint8List> buildCajaResumenEscPosSample({int lineWidth = 48}) async {
    final b = BytesBuilder();
    final lw = await _preferredLineWidth();
    void init() {
      b.add([0x1B, 0x40]);
    }

    void alignCenter() => b.add([0x1B, 0x61, 0x01]);
    void alignLeft() => b.add([0x1B, 0x61, 0x00]);
    void boldOn() => b.add([0x1B, 0x45, 0x01]);
    void boldOff() => b.add([0x1B, 0x45, 0x00]);
    void sizeNormal() => b.add([0x1D, 0x21, 0x00]);
    void sizeDouble() => b.add([0x1D, 0x21, 0x11]);
    void feed([int n = 1]) => b.add(List<int>.filled(n, 0x0A));
    String sep() => ''.padLeft(lw, '=');
    void text(String s) {
      b.add(utf8.encode(s));
      feed();
    }

    init();
    // Logo si está disponible y preferido
    bool withLogo = true;
    try {
      final sp = await SharedPreferences.getInstance();
      withLogo = sp.getBool('print_logo_escpos') ?? true;
    } catch (_) {}
    if (withLogo) {
      try {
        final data =
            await rootBundle.load('assets/icons/app_icon_foreground.png');
        final decoded = img.decodeImage(Uint8List.view(data.buffer));
        if (decoded != null) {
          final targetW = lw >= 48 ? 576 : (lw >= 42 ? 512 : 384);
          final scaled = img.copyResize(decoded,
              width: targetW, interpolation: img.Interpolation.average);
          _appendRasterImage(b, scaled);
          feed();
        }
      } catch (_) {}
    }

    alignCenter();
    boldOn();
    text(sep());
    sizeDouble();
    text('CIERRE DE CAJA');
    sizeNormal();
    text(sep());
    alignLeft();
    boldOff();
    final now = DateTime.now();
    final fecha =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final hora =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    text('Codigo caja: DEMO-001');
    text('Estado: Cerrada');
    text('Fecha apertura: $fecha $hora');
    text('Cajero apertura: Demo User');
    text('Unidad de gestión: General');
    feed();
    boldOn();
    text('TOTALES POR MEDIO DE PAGO');
    boldOff();
    text('Efectivo: ${_formatCurrency(32450)}');
    text('Transferencia: ${_formatCurrency(18750)}');
    boldOn();
    text('TOTAL: ${_formatCurrency(51200)}');
    boldOff();
    feed();
    // --- CONCILIACION POR MEDIO DE PAGO ---
    boldOn();
    text('CONCILIACION POR MEDIO DE PAGO');
    boldOff();
    feed();
    boldOn();
    text('EFECTIVO');
    boldOff();
    text('Efectivo esperado: ${_formatCurrency(37450)}');
    text('Efectivo declarado en caja: ${_formatCurrency(37450)}');
    boldOn();
    text('Diferencia efectivo: +${_formatCurrency(0)}');
    boldOff();
    feed();
    boldOn();
    text('TRANSFERENCIAS');
    boldOff();
    text('Transf. esperadas: ${_formatCurrency(18750)}');
    text('Transf. declaradas: ${_formatCurrency(18750)}');
    boldOn();
    text('Diferencia transf.: +${_formatCurrency(0)}');
    boldOff();
    feed();
    boldOn();
    text('DIFERENCIA TOTAL DEL EVENTO');
    text('+${_formatCurrency(0)}');
    boldOff();
    text('(Suma de diferencias por medio de pago)');
    feed();
    text('Tickets anulados: 0');
    feed();
    boldOn();
    text('ITEMS VENDIDOS:');
    boldOff();
    text('(Hamburguesa x 12) = ${_formatCurrency(24000)}');
    text('(Gaseosa x 20) = ${_formatCurrency(16000)}');
    text('(Papas x 8) = ${_formatCurrency(11200)}');
    // Demo de movimientos detallados (como en PDF)
    feed();
    boldOn();
    text('MOVIMIENTOS:');
    boldOff();
    final dd = now.day.toString().padLeft(2, '0');
    final mm = now.month.toString().padLeft(2, '0');
    text('$dd/$mm 19:45 INGRESO: ${_formatCurrency(5000)} - Fondo inicial');
    text('$dd/$mm 22:10 RETIRO: ${_formatCurrency(2000)} - Cambio caja');
    feed(2);
    b.add([0x1D, 0x56, 0x42, 0x00]);
    return Uint8List.fromList(b.toBytes());
  }

  /// Imprime solo por USB el cierre de caja de ejemplo
  Future<bool> printCajaResumenSampleUsbOnly() async {
    try {
      final bytes = await buildCajaResumenEscPosSample();
      if (bytes.isEmpty) return false;
      return await _usb.printBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  /// Construye bytes ESC/POS para cierre/resumen de caja
  Future<Uint8List> buildCajaResumenEscPos(int cajaId,
      {int lineWidth = 48}) async {
    final db = await AppDatabase.instance();
    final caja = await db.query('caja_diaria',
        where: 'id=?', whereArgs: [cajaId], limit: 1);
    final resumen = await CajaService().resumenCaja(cajaId);
    final movimientos = await db.rawQuery('''
            SELECT cm.*, mp.descripcion as medio_pago_desc
            FROM caja_movimiento cm
            LEFT JOIN metodos_pago mp ON mp.id = cm.medio_pago_id
            WHERE cm.caja_id=?
            ORDER BY cm.created_ts ASC
          ''', [cajaId]);
    // Desglose de movimientos por medio de pago (ESC/POS)
    double movIngEfecEsc = 0.0, movRetEfecEsc = 0.0, movIngTransfEsc = 0.0, movRetTransfEsc = 0.0;
    {
      final movMpTotalsEsc = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ing_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%efectivo%' THEN cm.monto END),0) as ret_efec,
          COALESCE(SUM(CASE WHEN cm.tipo='INGRESO' AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ing_transf,
          COALESCE(SUM(CASE WHEN cm.tipo='RETIRO'  AND LOWER(mp.descripcion) LIKE '%transfer%' THEN cm.monto END),0) as ret_transf
        FROM caja_movimiento cm
        LEFT JOIN metodos_pago mp ON mp.id = cm.medio_pago_id
        WHERE cm.caja_id=?
      ''', [cajaId]);
      movIngEfecEsc = (movMpTotalsEsc.first['ing_efec'] as num?)?.toDouble() ?? 0.0;
      movRetEfecEsc = (movMpTotalsEsc.first['ret_efec'] as num?)?.toDouble() ?? 0.0;
      movIngTransfEsc = (movMpTotalsEsc.first['ing_transf'] as num?)?.toDouble() ?? 0.0;
      movRetTransfEsc = (movMpTotalsEsc.first['ret_transf'] as num?)?.toDouble() ?? 0.0;
    }
    final c = caja.isNotEmpty ? caja.first : <String, Object?>{};
    final fondo = ((c['fondo_inicial'] as num?) ?? 0).toDouble();
    final efectivoDeclarado =
        ((c['conteo_efectivo_final'] as num?) ?? 0).toDouble();
    final transferenciasDeclaradas =
        ((c['conteo_transferencias_final'] as num?) ?? 0).toDouble();
    final obsApertura = (c['observaciones_apertura'] as String?) ?? '';
    final obsCierre = (c['obs_cierre'] as String?) ?? '';
    final obsPostCierreEsc = ((c['obs_post_cierre'] as String?) ?? '').trim();
    final obsPostCierre_tsEsc = ((c['obs_post_cierre_ts'] as String?) ?? '').trim();
    final descripcionEvento = (c['descripcion_evento'] as String?) ?? '';
    final diferencia = ((c['diferencia'] as num?) ?? 0).toDouble();
    final int? entradasVendidas = (c['entradas'] as num?)?.toInt();
    final codigoCaja = (c['codigo_caja'] ?? '').toString();
    final pvLabel = codigoCaja.trim().isNotEmpty
        ? await _buildPvLabelFromCajaCodigo(codigoCaja)
        : null;

    final totalesMp = (resumen['por_mp'] as List).cast<Map<String, Object?>>();
    final porProd =
        (resumen['por_producto'] as List).cast<Map<String, Object?>>();

    final b = BytesBuilder();
    final lw = await _preferredLineWidth();
    void init() {
      b.add([0x1B, 0x40]);
    }

    void alignCenter() => b.add([0x1B, 0x61, 0x01]);
    void alignLeft() => b.add([0x1B, 0x61, 0x00]);
    void boldOn() => b.add([0x1B, 0x45, 0x01]);
    void boldOff() => b.add([0x1B, 0x45, 0x00]);
    void sizeNormal() => b.add([0x1D, 0x21, 0x00]);
    void sizeDouble() => b.add([0x1D, 0x21, 0x11]);
    void feed([int n = 1]) => b.add(List<int>.filled(n, 0x0A));
    String clean(String s) {
      const map = {
        'á': 'a',
        'é': 'e',
        'í': 'i',
        'ó': 'o',
        'ú': 'u',
        'Á': 'A',
        'É': 'E',
        'Í': 'I',
        'Ó': 'O',
        'Ú': 'U',
        'ñ': 'n',
        'Ñ': 'N',
        'ü': 'u',
        'Ü': 'U'
      };
      return s.split('').map((c) => map[c] ?? c).join();
    }

    void text(String s) {
      b.add(utf8.encode(clean(s)));
      feed();
    }

    void writeWrapped(String prefix, String value) {
      final full = clean('$prefix$value');
      final runes = full.runes.toList();
      for (var i = 0; i < runes.length; i += lw) {
        final end = (i + lw < runes.length) ? i + lw : runes.length;
        final chunk = String.fromCharCodes(runes.sublist(i, end));
        text(chunk);
      }
    }

    String sep() => ''.padLeft(lw, '=');

    init();
    // Preferencia: imprimir logo en cierre (ESC/POS)
    bool withLogo = true;
    try {
      final sp = await SharedPreferences.getInstance();
      withLogo = sp.getBool('print_logo_escpos') ?? true;
    } catch (_) {}
    // Intentar imprimir logo pequeño arriba
    if (withLogo) {
      try {
        final data =
            await rootBundle.load('assets/icons/app_icon_foreground.png');
        final decoded = img.decodeImage(Uint8List.view(data.buffer));
        if (decoded != null) {
          // Elegir ancho objetivo según ancho preferido
          final targetW = lw >= 48 ? 576 : (lw >= 42 ? 512 : 384);
          final scaled = img.copyResize(decoded,
              width: targetW, interpolation: img.Interpolation.average);
          _appendRasterImage(b, scaled);
          feed();
        }
      } catch (_) {}
    }
    alignCenter();
    boldOn();
    text(sep());
    sizeDouble();
    text('CIERRE DE CAJA');
    sizeNormal();
    text(sep());
    alignLeft();
    boldOff();
    text(codigoCaja);
    if (pvLabel != null && pvLabel.trim().isNotEmpty) {
      text('PV: ${pvLabel.trim()}');
    }
    if ((c['estado'] as String?) != null) {
      text('Estado: ${c['estado']}');
    }
    text('Fecha apertura: ${(c['fecha'] ?? '')} ${(c['hora_apertura'] ?? '')}');
    text('Cajero apertura: ${c['cajero_apertura'] ?? ''}');
    text('Unidad de gestión: ${c['disciplina'] ?? ''}');
    if (descripcionEvento.isNotEmpty) {
      writeWrapped('Descripcion evento: ', descripcionEvento);
    }
    final cierreDt = (c['cierre_dt'] as String?);
    if (cierreDt != null) {
      text('Fecha cierre: $cierreDt');
    }
    final cajCierre = (c['cajero_cierre'] as String?);
    if (cajCierre != null && cajCierre.isNotEmpty) {
      text('Cajero de cierre: $cajCierre');
    }
    if (obsApertura.isNotEmpty) writeWrapped('Obs. apertura: ', obsApertura);
    if (obsCierre.isNotEmpty) writeWrapped('Obs. cierre: ', obsCierre);
    feed();
    // --- FONDO INICIAL ---
    boldOn();
    text('FONDO INICIAL');
    boldOff();
    text('Saldo inicial de caja: ${_formatCurrency(fondo)}');
    feed();
    // --- RESUMEN DE VENTAS ---
    boldOn();
    text('RESUMEN DE VENTAS');
    boldOff();
    for (final m in totalesMp) {
      final mpdesc = (m['mp_desc'] as String?) ?? 'MP ${m['mp']}';
      final tot = ((m['total'] as num?) ?? 0).toDouble();
      text('$mpdesc: ${_formatCurrency(tot)}');
    }
    boldOn();
    text(
        'TOTAL VENDIDO: ${_formatCurrency(((resumen['total'] as num?) ?? 0).toDouble())}');
    boldOff();
    feed();
    // --- MOVIMIENTOS DE CAJA ---
    final ingTotalEsc = movIngEfecEsc + movIngTransfEsc;
    final retTotalEsc = movRetEfecEsc + movRetTransfEsc;
    double ventasEfecEsc = 0;
    for (final m in totalesMp) {
      final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
      if (desc.contains('efectivo')) {
        ventasEfecEsc += ((m['total'] as num?) ?? 0).toDouble();
      }
    }
    boldOn();
    text('MOVIMIENTOS DE CAJA');
    boldOff();
    text('+ Ingresos extra: ${_formatCurrency(ingTotalEsc)}');
    if (movIngEfecEsc > 0) text('    Efectivo: ${_formatCurrency(movIngEfecEsc)}');
    if (movIngTransfEsc > 0) text('    Transferencia: ${_formatCurrency(movIngTransfEsc)}');
    for (final m in movimientos) {
      final tipo = (m['tipo'] ?? '').toString().toUpperCase();
      if (tipo != 'INGRESO') continue;
      final ts = (m['created_ts'] as num?)?.toInt();
      String tsStr = '';
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        final dd = dt.day.toString().padLeft(2, '0');
        final mmm = dt.month.toString().padLeft(2, '0');
        final hh = dt.hour.toString().padLeft(2, '0');
        final mi = dt.minute.toString().padLeft(2, '0');
        tsStr = '$dd/$mmm $hh:$mi';
      }
      final monto = ((m['monto'] as num?) ?? 0).toDouble();
      final obs = (m['observacion'] as String?)?.trim();
      final obsPart = (obs != null && obs.isNotEmpty) ? ' $obs' : '';
      final mpDesc = (m['medio_pago_desc'] as String?) ?? 'Efectivo';
      writeWrapped('', '* $tsStr Ingreso: ${_formatCurrency(monto)} ($mpDesc)$obsPart');
    }
    text('- Retiros: ${_formatCurrency(retTotalEsc)}');
    if (movRetEfecEsc > 0) text('    Efectivo: ${_formatCurrency(movRetEfecEsc)}');
    if (movRetTransfEsc > 0) text('    Transferencia: ${_formatCurrency(movRetTransfEsc)}');
    for (final m in movimientos) {
      final tipo = (m['tipo'] ?? '').toString().toUpperCase();
      if (tipo != 'RETIRO') continue;
      final ts = (m['created_ts'] as num?)?.toInt();
      String tsStr = '';
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        final dd = dt.day.toString().padLeft(2, '0');
        final mmm = dt.month.toString().padLeft(2, '0');
        final hh = dt.hour.toString().padLeft(2, '0');
        final mi = dt.minute.toString().padLeft(2, '0');
        tsStr = '$dd/$mmm $hh:$mi';
      }
      final monto = ((m['monto'] as num?) ?? 0).toDouble();
      final obs = (m['observacion'] as String?)?.trim();
      final obsPart = (obs != null && obs.isNotEmpty) ? ' $obs' : '';
      final mpDesc = (m['medio_pago_desc'] as String?) ?? 'Efectivo';
      writeWrapped('', '* $tsStr Retiro: ${_formatCurrency(monto)} ($mpDesc)$obsPart');
    }
    feed();
    final totalMovEfectivoEsc = ventasEfecEsc + movIngEfecEsc - movRetEfecEsc;
    boldOn();
    text('TOTAL MOV. EFECTIVO DEL DIA: ${totalMovEfectivoEsc >= 0 ? '+' : ''}${_formatCurrency(totalMovEfectivoEsc)}');
    boldOff();
    text('(${_formatCurrency(ventasEfecEsc)} + ${_formatCurrency(movIngEfecEsc)} - ${_formatCurrency(movRetEfecEsc)})');
    feed();
    // --- CONCILIACIÓN POR MEDIO DE PAGO ---
    final cajaEsperadaEsc = fondo + ventasEfecEsc + movIngEfecEsc - movRetEfecEsc;
    boldOn();
    text('CONCILIACION POR MEDIO DE PAGO');
    boldOff();
    feed();
    // -- EFECTIVO --
    boldOn();
    text('EFECTIVO');
    boldOff();
    text('Efectivo esperado: ${_formatCurrency(cajaEsperadaEsc)}');
    text('(Fondo ${_formatCurrency(fondo)} + Ventas ${_formatCurrency(ventasEfecEsc)} + Ing. ${_formatCurrency(movIngEfecEsc)} - Ret. ${_formatCurrency(movRetEfecEsc)})');
    text('Efectivo declarado: ${_formatCurrency(efectivoDeclarado)}');
    final difEfectivo = efectivoDeclarado - cajaEsperadaEsc;
    boldOn();
    text('Diferencia efectivo: ${difEfectivo >= 0 ? '+' : ''}${_formatCurrency(difEfectivo)}');
    boldOff();
    feed();
    // -- TRANSFERENCIAS --
    double ventasTransfConc = 0;
    for (final m in totalesMp) {
      final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
      if (desc.contains('transfer')) {
        ventasTransfConc += ((m['total'] as num?) ?? 0).toDouble();
      }
    }
    final transfEsperadas = ventasTransfConc + movIngTransfEsc - movRetTransfEsc;
    boldOn();
    text('TRANSFERENCIAS');
    boldOff();
    text('Transf. esperadas: ${_formatCurrency(transfEsperadas)}');
    text('(Ventas ${_formatCurrency(ventasTransfConc)} + Ing. ${_formatCurrency(movIngTransfEsc)} - Ret. ${_formatCurrency(movRetTransfEsc)})');
    text('Transf. declaradas: ${_formatCurrency(transferenciasDeclaradas)}');
    final difTransf = transferenciasDeclaradas - transfEsperadas;
    boldOn();
    text('Diferencia transf.: ${difTransf >= 0 ? '+' : ''}${_formatCurrency(difTransf)}');
    boldOff();
    feed();
    // -- DIFERENCIA TOTAL --
    final difTotal = difEfectivo + difTransf;
    boldOn();
    text('DIFERENCIA TOTAL DEL EVENTO');
    text('${difTotal >= 0 ? '+' : ''}${_formatCurrency(difTotal)}');
    boldOff();
    text('(Suma de diferencias por medio de pago)');
    feed();
    // --- RESULTADO ECONÓMICO DEL EVENTO ---
    double ventasTransfEsc = 0;
    for (final m in totalesMp) {
      final desc = ((m['mp_desc'] as String?) ?? '').toLowerCase();
      if (desc.contains('transfer')) {
        ventasTransfEsc += ((m['total'] as num?) ?? 0).toDouble();
      }
    }
    final resultadoNetoEsc = ventasEfecEsc + ventasTransfEsc + ingTotalEsc - retTotalEsc - fondo;
    boldOn();
    text('RESULTADO ECONOMICO DEL EVENTO');
    boldOff();
    text('Ventas en efectivo:       ${_formatCurrency(ventasEfecEsc)}');
    text('Ventas por transferencia: ${_formatCurrency(ventasTransfEsc)}');
    text('Otros ingresos efec.:     ${_formatCurrency(movIngEfecEsc)}');
    text('Otros ingresos transf.:   ${_formatCurrency(movIngTransfEsc)}');
    text('Retiros efec.:           (${_formatCurrency(movRetEfecEsc)})');
    text('Retiros transf.:         (${_formatCurrency(movRetTransfEsc)})');
    text('Saldo inicial caja:      (${_formatCurrency(fondo)})');
    boldOn();
    text('RESULTADO NETO: ${_formatCurrency(resultadoNetoEsc)}');
    boldOff();
    text('(${_formatCurrency(ventasEfecEsc)} + ${_formatCurrency(ventasTransfEsc)} + ${_formatCurrency(ingTotalEsc)} - ${_formatCurrency(retTotalEsc)} - ${_formatCurrency(fondo)})');
    feed();
    // --- RESULTADO NETO + DIFERENCIAS ---
    final resultadoConDifEsc = resultadoNetoEsc + difEfectivo + difTransf;
    boldOn();
    text('RESULTADO NETO + DIFERENCIAS');
    boldOff();
    text('Dif. efectivo: ${difEfectivo >= 0 ? '+' : ''}${_formatCurrency(difEfectivo)}');
    text('Dif. transferencias: ${difTransf >= 0 ? '+' : ''}${_formatCurrency(difTransf)}');
    boldOn();
    text('TOTAL: ${_formatCurrency(resultadoConDifEsc)}');
    boldOff();
    text('(${_formatCurrency(resultadoNetoEsc)} + ${_formatCurrency(difEfectivo)} + ${_formatCurrency(difTransf)})');
    feed();
    text(
        'Entradas vendidas: ${entradasVendidas == null ? '-' : entradasVendidas}');
    text('Tickets vendidos: ${(resumen['tickets']['emitidos'] ?? 0)}');
    text('Tickets anulados: ${(resumen['tickets']['anulados'] ?? 0)}');
    feed();
    boldOn();
    text('ITEMS VENDIDOS:');
    boldOff();
    for (final p in porProd) {
      final name = (p['nombre'] ?? '').toString();
      final cant = (p['cantidad'] ?? 0).toString();
      final tot = ((p['total'] as num?) ?? 0).toDouble();
      text('$name x $cant = ${_formatCurrency(tot)}');
    }
    if (obsPostCierreEsc.isNotEmpty) {
      feed();
      boldOn();
      text('OBS. POST-CIERRE:');
      boldOff();
      if (obsPostCierre_tsEsc.isNotEmpty) text('Fecha: $obsPostCierre_tsEsc');
      writeWrapped('', obsPostCierreEsc);
    }
    feed(2);
    b.add([0x1D, 0x56, 0x42, 0x00]); // corte parcial
    return Uint8List.fromList(b.toBytes());
  }

  // Convierte una imagen en formato ESC/POS raster (GS v 0)
  void _appendRasterImage(BytesBuilder b, img.Image image) {
    // Convertir a blanco y negro con umbral simple
    final grayscale = img.grayscale(image);
    // Reducir altura si es muy grande (para tickets)
    final maxH = 160; // aprox. 160px de alto
    final input = grayscale.height > maxH
        ? img.copyResize(grayscale,
            height: maxH, interpolation: img.Interpolation.average)
        : grayscale;

    final width = input.width;
    final height = input.height;
    final bytesPerRow = (width + 7) >> 3; // width/8 redondeado hacia arriba

    // Preparar encabezado ESC/POS: GS v 0 m xL xH yL yH
    // m=0 -> normal
    b.add([0x1D, 0x76, 0x30, 0x00]);
    final xL = bytesPerRow & 0xFF;
    final xH = (bytesPerRow >> 8) & 0xFF;
    final yL = height & 0xFF;
    final yH = (height >> 8) & 0xFF;
    b.add([xL, xH, yL, yH]);

    // Volcar pixeles, 1=negro
    for (int y = 0; y < height; y++) {
      int bit = 0;
      int byteVal = 0;
      for (int x = 0; x < width; x++) {
        final p = input.getPixel(x, y);
        final luma = img.getLuminance(p); // 0..255
        final isBlack = luma < 180; // umbral
        byteVal = (byteVal << 1) | (isBlack ? 1 : 0);
        bit++;
        if (bit == 8) {
          b.add([byteVal]);
          bit = 0;
          byteVal = 0;
        }
      }
      if (bit != 0) {
        // Relleno final de la fila si no múltiplo de 8
        byteVal <<= (8 - bit);
        b.add([byteVal]);
      }
    }
  }

  /// Intenta imprimir por USB; si falla, abre PDF del sistema
  Future<bool> printTicketUsbOrPdf(int ticketId) async {
    try {
      final bytes = await buildTicketEscPos(ticketId);
      if (bytes.isNotEmpty) {
        final ok = await _usb.printBytes(bytes);
        if (ok) return true;
      }
    } catch (_) {
      // fallback a PDF
    }
    await printTicket(ticketId);
    return false; // no se pudo por USB
  }

  /// Solo USB: retorna true si imprimió; no hace fallback
  Future<bool> printTicketUsbOnly(int ticketId) async {
    try {
      final bytes = await buildTicketEscPos(ticketId);
      if (bytes.isEmpty) return false;
      return await _usb.printBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  Future<bool> printVentaTicketsForVentaUsbOrPdf(int ventaId) async {
    final db = await AppDatabase.instance();
    final rows = await db.query('tickets',
        columns: ['id'],
        where: 'venta_id=?',
        whereArgs: [ventaId],
        orderBy: 'id');
    bool anyUsb = false;
    for (final r in rows) {
      final id = r['id'] as int;
      final ok = await printTicketUsbOrPdf(id);
      anyUsb = anyUsb || ok;
    }
    return anyUsb;
  }

  Future<bool> printVentaTicketsForVentaUsbOnly(int ventaId) async {
    final db = await AppDatabase.instance();
    final rows = await db.query('tickets',
        columns: ['id'],
        where: 'venta_id=?',
        whereArgs: [ventaId],
        orderBy: 'id');
    bool allOk = true;
    for (final r in rows) {
      final id = r['id'] as int;
      final ok = await printTicketUsbOnly(id)
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
      allOk = allOk && ok;
    }
    return allOk;
  }

  Future<bool> printCajaResumenUsbOrPdf(int cajaId) async {
    try {
      final bytes = await buildCajaResumenEscPos(cajaId);
      if (bytes.isNotEmpty) {
        final ok = await _usb.printBytes(bytes);
        if (ok) return true;
      }
    } catch (_) {}
    await printCajaResumen(cajaId);
    return false;
  }

  Future<bool> printCajaResumenUsbOnly(int cajaId) async {
    try {
      final bytes = await buildCajaResumenEscPos(cajaId);
      if (bytes.isEmpty) return false;
      return await _usb.printBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  /// Construye bytes ESC/POS para un resumen SUMARIZADO del evento (multi-caja).
  /// Pensado para imprimir rápido por USB cuando hay impresora conectada.
  Future<Uint8List> buildEventoResumenEscPos({
    required String fecha, // YYYY-MM-DD
    required String disciplina,
    required List<int> cajaIds,
  }) async {
    if (cajaIds.isEmpty) return Uint8List(0);

    final db = await AppDatabase.instance();
    final resumen = await CajaService().resumenCajas(cajaIds);

    final placeholders = List.filled(cajaIds.length, '?').join(',');

    final cajas = await db.rawQuery('''
      SELECT id, codigo_caja, alias_caja, diferencia
      FROM caja_diaria
      WHERE id IN ($placeholders)
      ORDER BY id ASC
    ''', cajaIds);

    final mov = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN tipo='INGRESO' THEN monto END),0) as ingresos,
        COALESCE(SUM(CASE WHEN tipo='RETIRO' THEN monto END),0) as retiros
      FROM caja_movimiento
      WHERE caja_id IN ($placeholders)
    ''', cajaIds);

    double sumFondo = 0.0;
    double sumEfecDeclarado = 0.0;
    int sumEntradas = 0;
    bool anyEntradas = false;
    try {
      final sums = await db.rawQuery('''
        SELECT
          COALESCE(SUM(fondo_inicial),0) as fondo,
          COALESCE(SUM(conteo_efectivo_final),0) as efectivo,
          COALESCE(SUM(entradas),0) as entradas,
          COUNT(entradas) as entradas_count
        FROM caja_diaria
        WHERE id IN ($placeholders)
      ''', cajaIds);
      if (sums.isNotEmpty) {
        sumFondo = ((sums.first['fondo'] as num?) ?? 0).toDouble();
        sumEfecDeclarado = ((sums.first['efectivo'] as num?) ?? 0).toDouble();
        sumEntradas = ((sums.first['entradas'] as num?) ?? 0).toInt();
        anyEntradas =
            (((sums.first['entradas_count'] as num?) ?? 0).toInt() > 0);
      }
    } catch (e, st) {
      AppDatabase.logLocalError(
        scope: 'print_service.evento_resumen_escpos.sums',
        error: e,
        stackTrace: st,
        payload: {'fecha': fecha, 'disciplina': disciplina},
      );
    }

    final totalesMp = (resumen['por_mp'] as List?)
            ?.cast<Map<String, Object?>>()
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
    final total = ((resumen['total'] as num?) ?? 0).toDouble();
    final tickets = (resumen['tickets'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final ticketsAnulados = (tickets['anulados'] as num?)?.toInt() ?? 0;
    final ticketsEmitidos = (tickets['emitidos'] as num?)?.toInt() ?? 0;

    double diferenciaGlobal = 0.0;
    for (final c in cajas) {
      diferenciaGlobal += ((c['diferencia'] as num?) ?? 0).toDouble();
    }

    final ingresos = (mov.isNotEmpty
        ? ((mov.first['ingresos'] as num?) ?? 0).toDouble()
        : 0.0);
    final retiros = (mov.isNotEmpty
        ? ((mov.first['retiros'] as num?) ?? 0).toDouble()
        : 0.0);

    final b = BytesBuilder();
    final lw = await _preferredLineWidth();

    void init() {
      b.add([0x1B, 0x40]);
    }

    void alignCenter() => b.add([0x1B, 0x61, 0x01]);
    void alignLeft() => b.add([0x1B, 0x61, 0x00]);
    void boldOn() => b.add([0x1B, 0x45, 0x01]);
    void boldOff() => b.add([0x1B, 0x45, 0x00]);
    void sizeNormal() => b.add([0x1D, 0x21, 0x00]);
    void sizeDouble() => b.add([0x1D, 0x21, 0x11]);
    void feed([int n = 1]) => b.add(List<int>.filled(n, 0x0A));

    String clean(String s) {
      const map = {
        'á': 'a',
        'é': 'e',
        'í': 'i',
        'ó': 'o',
        'ú': 'u',
        'Á': 'A',
        'É': 'E',
        'Í': 'I',
        'Ó': 'O',
        'Ú': 'U',
        'ñ': 'n',
        'Ñ': 'N',
        'ü': 'u',
        'Ü': 'U'
      };
      return s.split('').map((c) => map[c] ?? c).join();
    }

    void text(String s) {
      b.add(utf8.encode(clean(s)));
      feed();
    }

    void writeWrapped(String value) {
      final full = clean(value);
      final runes = full.runes.toList();
      for (var i = 0; i < runes.length; i += lw) {
        final end = (i + lw < runes.length) ? i + lw : runes.length;
        final chunk = String.fromCharCodes(runes.sublist(i, end));
        text(chunk);
      }
    }

    String sep() => ''.padLeft(lw, '=');

    init();
    alignCenter();
    boldOn();
    text(sep());
    sizeDouble();
    text('RESUMEN EVENTO');
    sizeNormal();
    text(sep());
    boldOff();
    alignLeft();

    writeWrapped('Unidad de gestión: $disciplina');
    text('Fecha: $fecha');
    text('Cajas incluidas: ${cajaIds.length}');
    feed();

    boldOn();
    text('TOTALES POR MEDIO DE PAGO');
    boldOff();
    for (final m in totalesMp) {
      final mpdesc = (m['mp_desc'] as String?) ?? 'MP ${m['mp']}';
      final tot = ((m['total'] as num?) ?? 0).toDouble();
      text('$mpdesc: ${_formatCurrency(tot)}');
    }

    sizeDouble();
    boldOn();
    text('TOTAL: ${_formatCurrency(total)}');
    boldOff();
    sizeNormal();
    feed();

    text('Fondo inicial (suma): ${_formatCurrency(sumFondo)}');
    text('Efectivo declarado (suma): ${_formatCurrency(sumEfecDeclarado)}');
    text('Ingresos registrados: ${_formatCurrency(ingresos)}');
    text('Retiros registrados: ${_formatCurrency(retiros)}');
    boldOn();
    text('Diferencia global: ${_formatCurrency(diferenciaGlobal)}');
    boldOff();
    text('Entradas vendidas (suma): ${anyEntradas ? sumEntradas : '-'}');
    text('Tickets vendidos: $ticketsEmitidos');
    text('Tickets anulados: $ticketsAnulados');
    feed();

    boldOn();
    text('CAJAS');
    boldOff();
    for (final c in cajas) {
      final codigo = (c['codigo_caja'] ?? '').toString();
      final alias = (c['alias_caja'] ?? '').toString().trim();
      final label = alias.isNotEmpty ? '$codigo • $alias' : codigo;
      writeWrapped(label);
    }

    feed(2);
    b.add([0x1D, 0x56, 0x42, 0x00]);
    return Uint8List.fromList(b.toBytes());
  }

  /// Solo USB: imprime el resumen SUMARIZADO del evento (no hace fallback a PDF).
  Future<bool> printEventoResumenUsbOnly({
    required String fecha,
    required String disciplina,
    required List<int> cajaIds,
  }) async {
    try {
      final bytes = await buildEventoResumenEscPos(
        fecha: fecha,
        disciplina: disciplina,
        cajaIds: cajaIds,
      );
      if (bytes.isEmpty) return false;
      return await _usb.printBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  /// Abre el diálogo de impresión del sistema para un ticket
  Future<void> printTicket(int ticketId) async {
    await Printing.layoutPdf(
      onLayout: (format) async => buildTicketPdf(ticketId),
      name: 'ticket_$ticketId.pdf',
    );
  }

  /// Imprime todos los tickets de una venta (uno por ítem)
  Future<void> printVentaTicketsForVenta(int ventaId) async {
    final db = await AppDatabase.instance();
    final rows = await db.query('tickets',
        columns: ['id'],
        where: 'venta_id=?',
        whereArgs: [ventaId],
        orderBy: 'id');
    for (final r in rows) {
      final id = r['id'] as int;
      await printTicket(id);
    }
  }

  /// Abre el diálogo de impresión con el resumen/cierre de caja
  Future<void> printCajaResumen(int cajaId) async {
    await Printing.layoutPdf(
      onLayout: (format) async => buildCajaResumenPdf(cajaId),
      name: 'cierre_caja_$cajaId.pdf',
    );
  }

  String _formatCurrency(num v) {
    // Formato simple $ 1234.56 (rápido y portable)
    final s = v.toStringAsFixed(2);
    return '\$ $s';
  }
}
