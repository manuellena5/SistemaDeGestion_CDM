import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/dao/db.dart';
import '../services/caja_service.dart';
import '../../shared/services/movimiento_service.dart';
import '../../shared/services/print_service.dart';
import '../../shared/services/usb_printer_service.dart';
import '../../shared/services/export_service.dart';
import '../../shared/format.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import '../../shared/state/app_settings.dart';
import '../../shared/widgets/bill_counter_dialog.dart';
import 'sales_list_page.dart';
import '../../eventos/pages/detalle_evento_page.dart';
import '../../home/home_page.dart';
import '../../tesoreria/pages/movimientos_page.dart';
import '../../shared/pages/printer_test_page.dart';

class CajaPage extends StatefulWidget {
  const CajaPage({super.key, this.cajaId});

  /// Si se provee, abre una caja histórica por id (solo lectura).
  /// Si es null, muestra la caja ABIERTA actual (flujo operativo).
  final int? cajaId;

  @override
  State<CajaPage> createState() => _CajaPageState();
}

class _CajaPageState extends State<CajaPage> {
  final _svc = CajaService();
  Map<String, dynamic>? _caja;
  Map<String, dynamic>? _resumen;
  bool _loading = true;
  double _movIngresos = 0.0;
  double _movRetiros = 0.0;
  // Desglose de movimientos por medio de pago
  double _movIngresosEfectivo = 0.0;
  double _movRetirosEfectivo = 0.0;
  double _movIngresosTransferencia = 0.0;
  double _movRetirosTransferencia = 0.0;

  int? get _cajaId => _caja?['id'] as int?;

  final _usuario = TextEditingController(text: '');
  final _efectivo = TextEditingController(text: '');
  final _transfer = TextEditingController(text: '');
  final _obs = TextEditingController();
  final _entradas = TextEditingController(text: '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usuario.dispose();
    _efectivo.dispose();
    _transfer.dispose();
    _obs.dispose();
    _entradas.dispose();
    super.dispose();
  }

  Future<(bool, String?)> _loadPrinterStatus() async {
    final svc = UsbPrinterService();
    final connected = await svc.isConnected();
    final saved = await svc.getDefaultDevice();
    final name = saved?['deviceName'] as String?;
    return (connected, name);
  }

  Future<void> _load() async {
    final cajaId = widget.cajaId;
    final caja = cajaId != null
        ? await _svc.getCajaById(cajaId)
        : await _svc.getCajaAbierta();
    Map<String, dynamic>? resumen;
    var movIngresos = 0.0;
    var movRetiros = 0.0;
    var movIngEfec = 0.0;
    var movRetEfec = 0.0;
    var movIngTransf = 0.0;
    var movRetTransf = 0.0;

    if (caja != null) {
      resumen = await _svc.resumenCaja(caja['id'] as int);
      try {
        final mt = await MovimientoService().totalesPorCaja(caja['id'] as int);
        movIngresos = (mt['ingresos'] as num?)?.toDouble() ?? 0.0;
        movRetiros = (mt['retiros'] as num?)?.toDouble() ?? 0.0;
        // Desglose por medio de pago
        final mtMp = await MovimientoService().totalesPorCajaPorMp(caja['id'] as int);
        movIngEfec = (mtMp['ingresosEfectivo'] as num?)?.toDouble() ?? 0.0;
        movRetEfec = (mtMp['retirosEfectivo'] as num?)?.toDouble() ?? 0.0;
        movIngTransf = (mtMp['ingresosTransferencia'] as num?)?.toDouble() ?? 0.0;
        movRetTransf = (mtMp['retirosTransferencia'] as num?)?.toDouble() ?? 0.0;
      } catch (e, st) {
        AppDatabase.logLocalError(
          scope: 'caja_page.totales_movimientos',
          error: e,
          stackTrace: st,
          payload: {'cajaId': caja['id']},
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _caja = caja;
      _resumen = resumen;
      _movIngresos = movIngresos;
      _movRetiros = movRetiros;
      _movIngresosEfectivo = movIngEfec;
      _movRetirosEfectivo = movRetEfec;
      _movIngresosTransferencia = movIngTransf;
      _movRetirosTransferencia = movRetTransf;
      _loading = false;
    });
  }

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
      return alias.isNotEmpty ? '$pvCodigo • $alias' : pvCodigo;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'caja_page.pv_label',
        error: e,
        stackTrace: st,
        payload: {'codigo_caja': codigoCaja},
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_caja == null) {
      return const Scaffold(body: Center(child: Text('No hay caja abierta')));
    }

    final resumen = _resumen ?? <String, dynamic>{};
    final cs = Theme.of(context).colorScheme;

    context.watch<AppSettings?>();

    final codigoCaja = (_caja!['codigo_caja'] ?? '').toString();
    final estado = (_caja!['estado'] ?? 'ABIERTA').toString();
    final isAbierta = estado.toUpperCase().contains('ABIERTA');
    final readOnly = widget.cajaId != null || !isAbierta;
    final fecha = (_caja!['fecha'] ?? '').toString();
    final horaApertura = (_caja!['hora_apertura'] ?? '').toString();
    final disciplina = (_caja!['disciplina'] ?? '').toString();
    final cajeroApertura = (_caja!['cajero_apertura'] ?? '').toString();
    final cajeroCierre = (_caja!['cajero_cierre'] ?? '').toString();
    final descripcionEvento =
        ((_caja!['descripcion_evento'] as String?) ?? '').trim();
    final obsApertura =
        ((_caja!['observaciones_apertura'] as String?) ?? '').trim();
    final obsCierre = ((_caja!['obs_cierre'] as String?) ?? '').trim();
    final obsPostCierre = ((_caja!['obs_post_cierre'] as String?) ?? '').trim();
    final obsPostCierreTs = ((_caja!['obs_post_cierre_ts'] as String?) ?? '').trim();

    final fondo = ((_caja!['fondo_inicial'] as num?) ?? 0).toDouble();
    final efectivoDeclarado =
        ((_caja!['conteo_efectivo_final'] as num?) ?? 0).toDouble();
    final transferenciasFinal =
        (((_caja!['conteo_transferencias_final'] as num?) ??
                    (_caja!['transferencias_final'] as num?)) ??
                0)
            .toDouble();
    final diferencia = ((_caja!['diferencia'] as num?) ?? 0).toDouble();
    final entradasVendidas = (((_caja!['entradas'] as num?) ?? 0).toInt());
    final totalVentas = ((resumen['total'] as num?) ?? 0).toDouble();
    final ticketsEmitidos =
        ((resumen['tickets']?['emitidos'] as num?) ?? 0).toInt();
    final ticketsAnulados =
        ((resumen['tickets']?['anulados'] as num?) ?? 0).toInt();

    // Totales por MP
    double ventasEfec = 0.0;
    double ventasTransf = 0.0;
    final totalesMp = List<Map<String, dynamic>>.from(
        (resumen['por_mp'] as List?) ?? const []);
    for (final m in totalesMp) {
      final desc = (m['mp_desc'] as String?)?.toLowerCase() ?? '';
      final monto = ((m['total'] as num?) ?? 0).toDouble();
      if (desc.contains('efectivo')) ventasEfec += monto;
      if (desc.contains('transfer')) ventasTransf += monto;
    }

    // Ventas por producto
    final porProducto = List<Map<String, dynamic>>.from(
        (resumen['por_producto'] as List?) ?? const []);

    final isWide = MediaQuery.of(context).size.width >= 900;

    final detallesEventoSection = _SectionCard(
      title: 'Detalles del Evento',
      icon: Icons.event,
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Unidad de gestión', disciplina.isEmpty ? '—' : disciplina),
                    const SizedBox(height: 10),
                    FutureBuilder<String?>(
                      future: _buildPvLabelFromCajaCodigo(codigoCaja),
                      builder: (ctx, snap) {
                        final v = (snap.data ?? '').trim();
                        return _kv('Punto de venta', v.isEmpty ? '—' : v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _kv('Cajera',
                        cajeroApertura.isEmpty ? '—' : cajeroApertura),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Descripción',
                        descripcionEvento.isEmpty ? '—' : descripcionEvento),
                    const SizedBox(height: 10),
                    _kv(
                      'Observación Apertura',
                      obsApertura.isEmpty ? '—' : obsApertura,
                      italicValue: obsApertura.isNotEmpty,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final movimientosSection = _SectionCard(
      title: 'Movimientos de Caja',
      icon: Icons.account_balance_wallet,
      initiallyExpanded: true,
      child: Column(
        children: [
          _movementRow(
            context,
            icon: Icons.attach_money,
            title: 'Fondo Inicial',
            subtitle: 'Base de caja',
            value: formatCurrency(fondo),
            valueStyle: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Divider(height: 16),
          _movementRow(
            context,
            icon: Icons.arrow_downward,
            title: 'Ingresos',
            subtitle: 'Efectivo: ${formatCurrency(_movIngresosEfectivo)} • Transf: ${formatCurrency(_movIngresosTransferencia)}',
            value: '+ ${formatCurrency(_movIngresos)}',
            valueStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700, color: AppColors.ingreso),
          ),
          const Divider(height: 16),
          _movementRow(
            context,
            icon: Icons.arrow_upward,
            title: 'Retiros',
            subtitle: 'Efectivo: ${formatCurrency(_movRetirosEfectivo)} • Transf: ${formatCurrency(_movRetirosTransferencia)}',
            value: '- ${formatCurrency(_movRetiros)}',
            valueStyle: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700, color: cs.error),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final cajaId = _caja!['id'] as int;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => MovimientosPage(cajaId: cajaId)),
                );
                if (mounted) _load();
              },
              icon: const Icon(Icons.swap_vert),
              label: Text(readOnly
                  ? 'Ver movimientos'
                  : 'Ver detalle / Agregar movimientos'),
            ),
          ),
        ],
      ),
    );

    final ventasPorProductoSection = _SectionCard(
      title: 'Ventas por Producto',
      icon: Icons.shopping_cart,
      trailing: _Badge(text: '${porProducto.length} Items'),
      initiallyExpanded: false,
      child: porProducto.isEmpty
          ? const Text('Sin ventas registradas')
          : Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(2)
              },
              children: [
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Producto',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text('Cant.',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text('Total',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
                ...porProducto.map((p) {
                  final nom = (p['nombre'] ?? '').toString();
                  final cant = ((p['cantidad'] as num?) ?? 0).toInt();
                  final tot = ((p['total'] as num?) ?? 0).toDouble();
                  return TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(nom,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Align(
                            alignment: Alignment.center, child: Text('$cant')),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(formatCurrency(tot),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  );
                }),
              ],
            ),
    );

    final cierreSection = !readOnly
        ? _SectionCard(
            title: 'Conciliación de caja',
            icon: Icons.calculate,
            initiallyExpanded: true,
            child: Column(
              children: [
                TextField(
                  controller: _usuario,
                  decoration:
                      const InputDecoration(labelText: 'Cajero de cierre'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _efectivo,
                  decoration: InputDecoration(
                    labelText: 'Efectivo declarado',
                    suffixIcon: TextButton.icon(
                      icon: const Icon(Icons.calculate_outlined, size: 20),
                      label: const Text('Contar billetes', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () async {
                        final result = await showBillCounterDialog(context);
                        if (result != null) {
                          _efectivo.text = result.toStringAsFixed(0);
                        }
                      },
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _transfer,
                  decoration:
                      const InputDecoration(labelText: 'Transferencias'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _entradas,
                  decoration: const InputDecoration(
                      labelText: 'Entradas vendidas (opcional)'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    if (v.isEmpty) return;
                    final parsed = int.tryParse(v);
                    if (parsed == null || parsed < 0) {
                      final limpio = v.replaceAll(RegExp(r'[^0-9]'), '');
                      final safe =
                          limpio.isEmpty ? '' : int.parse(limpio).toString();
                      if (_entradas.text != safe) {
                        _entradas.text = safe;
                        _entradas.selection = TextSelection.fromPosition(
                            TextPosition(offset: _entradas.text.length));
                      }
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Sólo números enteros ≥ 0')));
                    }
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _obs,
                  decoration: const InputDecoration(labelText: 'Observación'),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.advertenciaDim,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.advertenciaDim),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info, size: 18, color: AppColors.advertencia),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Aún no se ha realizado el cierre de caja. Declare el efectivo para calcular la diferencia final.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: AppColors.advertencia),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                        child: Text('Tickets vendidos',
                            style: Theme.of(context).textTheme.bodySmall)),
                    Text('$ticketsEmitidos',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                        child: Text('Tickets anulados',
                            style: Theme.of(context).textTheme.bodySmall)),
                    Text('$ticketsAnulados',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
            ),
          )
        : Column(
            children: [
              // --- RESUMEN DE VENTAS ---
              _SectionCard(
                title: 'Resumen de Ventas',
                icon: Icons.shopping_bag,
                initiallyExpanded: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...totalesMp.map((m) {
                      final desc = (m['mp_desc'] as String?) ?? 'MP ${m['mp']}';
                      final monto = ((m['total'] as num?) ?? 0).toDouble();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(child: Text(desc, style: Theme.of(context).textTheme.bodyMedium)),
                            Text(formatCurrency(monto), style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 16),
                    Row(
                      children: [
                        Expanded(child: Text('TOTAL VENDIDO', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
                        Text(formatCurrency(totalVentas), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // --- CONCILIACIÓN POR MEDIO DE PAGO ---
              _SectionCard(
                title: 'Conciliación por Medio de Pago',
                icon: Icons.balance,
                initiallyExpanded: true,
                child: Builder(
                  builder: (context) {
                    final cajaEsperada = fondo + ventasEfec + _movIngresosEfectivo - _movRetirosEfectivo;
                    final difEfectivo = efectivoDeclarado - cajaEsperada;
                    final transfEsperadas = ventasTransf + _movIngresosTransferencia - _movRetirosTransferencia;
                    final difTransf = transferenciasFinal - transfEsperadas;
                    final difTotal = difEfectivo + difTransf;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('EFECTIVO', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        _kvRow(context, 'Efectivo esperado', formatCurrency(cajaEsperada)),
                        _kvRow(context, 'Efectivo declarado', formatCurrency(efectivoDeclarado)),
                        Row(
                          children: [
                            Expanded(child: Text('Diferencia efectivo', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
                            Text(
                              '${difEfectivo >= 0 ? '+' : ''}${formatCurrency(difEfectivo)}',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: difEfectivo == 0 ? AppColors.ingreso : (difEfectivo > 0 ? AppColors.info : AppColors.egreso),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('TRANSFERENCIAS', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        _kvRow(context, 'Transf. esperadas', formatCurrency(transfEsperadas)),
                        _kvRow(context, 'Transf. declaradas', formatCurrency(transferenciasFinal)),
                        Row(
                          children: [
                            Expanded(child: Text('Diferencia transf.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
                            Text(
                              '${difTransf >= 0 ? '+' : ''}${formatCurrency(difTransf)}',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: difTransf == 0 ? AppColors.ingreso : (difTransf > 0 ? AppColors.info : AppColors.egreso),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                        Text('DIFERENCIA TOTAL DEL EVENTO', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 4),
                        Text(
                          '${difTotal >= 0 ? '+' : ''}${formatCurrency(difTotal)}',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: difTotal == 0 ? AppColors.ingreso : (difTotal > 0 ? AppColors.info : AppColors.egreso),
                          ),
                        ),
                        Text('(Suma de diferencias por medio de pago)',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
                        const Divider(height: 16),
                        _kvRow(context, 'Entradas vendidas', entradasVendidas == 0 ? '—' : '$entradasVendidas'),
                        _kvRow(context, 'Tickets vendidos', '$ticketsEmitidos'),
                        _kvRow(context, 'Tickets anulados', '$ticketsAnulados'),
                        if (cajeroCierre.isNotEmpty) ...[const SizedBox(height: 6), _kvRow(context, 'Cajero de cierre', cajeroCierre)],
                        if (obsCierre.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _kv('Observación cierre', obsCierre, italicValue: true),
                        ],
                        if (obsPostCierre.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _kv(
                            'Obs. post-cierre${obsPostCierreTs.isNotEmpty ? ' ($obsPostCierreTs)' : ''}',
                            obsPostCierre,
                            italicValue: true,
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _mostrarDialogoObsPostCierre(),
                            icon: const Icon(Icons.edit_note, size: 18),
                            label: Text(obsPostCierre.isEmpty
                                ? 'Agregar observación post-cierre'
                                : 'Editar observación post-cierre'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // --- RESULTADO ECONÓMICO DEL EVENTO ---
              _SectionCard(
                title: 'Resultado Económico del Evento',
                icon: Icons.trending_up,
                initiallyExpanded: true,
                child: Builder(
                  builder: (context) {
                    final resultadoNeto = ventasEfec + ventasTransf + _movIngresos - _movRetiros - fondo;
                    // Diferencias por medio de pago (con desglose de movimientos)
                    final cajaEsperadaRes = fondo + ventasEfec + _movIngresosEfectivo - _movRetirosEfectivo;
                    final difEfectivoRes = efectivoDeclarado - cajaEsperadaRes;
                    final transfEsperadaRes = ventasTransf + _movIngresosTransferencia - _movRetirosTransferencia;
                    final difTransfRes = transferenciasFinal - transfEsperadaRes;
                    final resultadoConDif = resultadoNeto + difEfectivoRes + difTransfRes;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _kvRow(context, 'Ventas en efectivo', formatCurrency(ventasEfec)),
                        _kvRow(context, 'Ventas por transferencia', formatCurrency(ventasTransf)),
                        _kvRow(context, '+ Otros ingresos', formatCurrency(_movIngresos)),
                        _kvRow(context, '- Retiros', '(${formatCurrency(_movRetiros)})'),
                        _kvRow(context, '- Saldo inicial caja', '(${formatCurrency(fondo)})'),
                        const Divider(height: 16),
                        Row(
                          children: [
                            Expanded(child: Text('RESULTADO NETO', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
                            Text(formatCurrency(resultadoNeto), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: resultadoNeto >= 0 ? AppColors.ingreso : AppColors.egreso)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '(${formatCurrency(ventasEfec)} + ${formatCurrency(ventasTransf)} + ${formatCurrency(_movIngresos)} - ${formatCurrency(_movRetiros)} - ${formatCurrency(fondo)})',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                        ),
                        const Divider(height: 16),
                        Row(
                          children: [
                            Expanded(child: Text('RESULTADO NETO + DIFERENCIAS', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(child: Text('Diferencia efectivo', style: Theme.of(context).textTheme.bodyMedium)),
                            Text(
                              '${difEfectivoRes >= 0 ? '+' : ''}${formatCurrency(difEfectivoRes)}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: difEfectivoRes == 0 ? AppColors.ingreso : (difEfectivoRes > 0 ? AppColors.info : AppColors.egreso),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(child: Text('Diferencia transferencias', style: Theme.of(context).textTheme.bodyMedium)),
                            Text(
                              '${difTransfRes >= 0 ? '+' : ''}${formatCurrency(difTransfRes)}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: difTransfRes == 0 ? AppColors.ingreso : (difTransfRes > 0 ? AppColors.info : AppColors.egreso),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(child: Text('TOTAL', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
                            Text(
                              formatCurrency(resultadoConDif),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: resultadoConDif >= 0 ? AppColors.ingreso : AppColors.egreso,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '(${formatCurrency(resultadoNeto)} + ${formatCurrency(difEfectivoRes)} + ${formatCurrency(difTransfRes)})',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
    porProducto.sort((a, b) {
      final an = (a['cantidad'] as num?) ?? 0;
      final bn = (b['cantidad'] as num?) ?? 0;
      return bn.compareTo(an);
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(readOnly
            ? (codigoCaja.isEmpty ? 'Detalle de caja' : 'Caja $codigoCaja')
            : 'Estado de Caja'),
        actions: [
          IconButton(
            tooltip: 'Ver tickets (solo lectura)',
            icon: const Icon(Icons.receipt_long),
            onPressed: () async {
              final cajaId = _caja?['id'] as int?;
              if (cajaId == null) return;
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      SalesListPage(cajaId: cajaId, codigoCaja: codigoCaja),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Previsualización PDF',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _previewCajaPdf,
          ),
          FutureBuilder<(bool, String?)>(
            future: _loadPrinterStatus(),
            builder: (ctx, snap) {
              final connected = snap.data?.$1 ?? false;
              final devName = snap.data?.$2;
              final color = connected ? AppColors.ingreso : AppColors.egreso;
              final tooltip = connected
                  ? 'Impresora: Conectada${devName != null && devName.isNotEmpty ? ' ($devName)' : ''}\nTocar para imprimir'
                  : 'Impresora: No conectada\nTocar para imprimir';
              return IconButton(
                tooltip: tooltip,
                icon: Icon(Icons.print, color: color),
                onPressed: _printCajaConDecision,
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, readOnly ? 16 : 120),
          children: [
            _StatusCard(
              estado: estado,
              fecha: fecha,
              hora: horaApertura,
              codigoCaja: codigoCaja,
              syncEstado: (_caja!['sync_estado'] ?? '').toString(),
              syncLastError: (_caja!['sync_last_error'] as String?),
            ),
            const SizedBox(height: 12),
            if (isWide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _TotalVentasCard(
                      total: totalVentas,
                      efectivo: ventasEfec,
                      transferencia: ventasTransf,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: detallesEventoSection),
                ],
              )
            else ...[
              _TotalVentasCard(
                total: totalVentas,
                efectivo: ventasEfec,
                transferencia: ventasTransf,
              ),
              const SizedBox(height: 12),
              detallesEventoSection,
            ],
            const SizedBox(height: 12),
            if (isWide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: movimientosSection),
                  const SizedBox(width: 12),
                  Expanded(child: cierreSection),
                ],
              )
            else
              movimientosSection,
            const SizedBox(height: 12),
            if (isWide)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: ventasPorProductoSection,
                ),
              )
            else
              ventasPorProductoSection,
            if (!isWide) ...[
              const SizedBox(height: 12),
              cierreSection,
            ],
          ],
        ),
      ),
      bottomNavigationBar: readOnly
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _mostrarModalExportarCompartir,
                    icon: const Icon(Icons.table_chart),
                    label: const Text('Exportar a Excel / Compartir'),
                  ),
                ),
              ),
            )
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final cajaId = _caja!['id'] as int;
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => SalesListPage(
                                        cajaId: cajaId,
                                        codigoCaja: codigoCaja)),
                              );
                            },
                            icon: const Icon(Icons.history),
                            label: const Text('Historial'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: () => _cerrarCajaFlow(resumen: resumen),
                            icon: const Icon(Icons.lock),
                            label: const Text('Cerrar caja'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _cerrarCajaFlow({required Map<String, dynamic> resumen}) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);

    final eff = parseLooseDouble(_efectivo.text);
    final tr = parseLooseDouble(_transfer.text);
    final entradasRaw = _entradas.text.trim();
    final entradas = entradasRaw.isEmpty ? null : int.tryParse(entradasRaw);

    if (entradasRaw.isNotEmpty && entradas == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Entradas debe ser un entero ≥ 0')));
      return;
    }
    if (entradas != null && entradas < 0) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Entradas no puede ser negativo')));
      return;
    }
    if ((_usuario.text.trim()).isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Cajero de cierre requerido')));
      return;
    }

    final totalVentas = (resumen['total'] as num?)?.toDouble() ?? 0.0;
    final fondo = (_caja!['fondo_inicial'] as num?)?.toDouble() ?? 0.0;
    final movTotals =
        await MovimientoService().totalesPorCaja(_caja!['id'] as int);
    final ingresos = (movTotals['ingresos'] as num?)?.toDouble() ?? 0.0;
    final retiros = (movTotals['retiros'] as num?)?.toDouble() ?? 0.0;
    // Desglose por medio de pago
    final movTotalsMp =
        await MovimientoService().totalesPorCajaPorMp(_caja!['id'] as int);
    final ingEfec = (movTotalsMp['ingresosEfectivo'] as num?)?.toDouble() ?? 0.0;
    final retEfec = (movTotalsMp['retirosEfectivo'] as num?)?.toDouble() ?? 0.0;
    final ingTransf = (movTotalsMp['ingresosTransferencia'] as num?)?.toDouble() ?? 0.0;
    final retTransf = (movTotalsMp['retirosTransferencia'] as num?)?.toDouble() ?? 0.0;
    final totalPorFormula = (eff - fondo - ingEfec + retEfec) + tr;
    final diferencia = totalPorFormula - totalVentas;

    final tickets = (resumen['tickets'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final ticketsVendidos = (tickets['emitidos'] as num?)?.toInt() ?? 0;
    final ticketsAnulados = (tickets['anulados'] as num?)?.toInt() ?? 0;

    // Calcular ventas en efectivo para el diálogo
    final porMpDialog = List<Map<String, dynamic>>.from(
        (resumen['por_mp'] as List?) ?? const []);
    final ventasEfectivoDialog = porMpDialog.fold<double>(
      0.0,
      (acc, e) =>
          (e['mp_desc']?.toString() ?? '').toLowerCase().contains('efectivo')
              ? acc + ((e['total'] as num?)?.toDouble() ?? 0.0)
              : acc,
    );
    final ventasTransfDialog = porMpDialog.fold<double>(
      0.0,
      (acc, e) =>
          (e['mp_desc']?.toString() ?? '').toLowerCase().contains('transfer')
              ? acc + ((e['total'] as num?)?.toDouble() ?? 0.0)
              : acc,
    );
    final cajaEsperadaDialog = fondo + ventasEfectivoDialog + ingEfec - retEfec;
    final transfEsperadaDialog = ventasTransfDialog + ingTransf - retTransf;
    final totalMovEfectivoDialog = ventasEfectivoDialog + ingEfec - retEfec;

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar cierre de caja'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // RESUMEN DE VENTAS
              Text('RESUMEN DE VENTAS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 4),
              ...porMpDialog.map((m) {
                final desc = (m['mp_desc'] as String?) ?? 'MP ${m['mp']}';
                final monto = ((m['total'] as num?) ?? 0).toDouble();
                return Text('  $desc: ${formatCurrency(monto)}');
              }),
              Text('TOTAL VENDIDO: ${formatCurrency(totalVentas)}',
                  style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              // MOVIMIENTOS DE CAJA
              Text('MOVIMIENTOS DE CAJA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 4),
              Text('+ Ingresos extra: ${formatCurrency(ingresos)}'),
              if (ingEfec > 0 || ingTransf > 0)
                Text('  (Efectivo: ${formatCurrency(ingEfec)} • Transf: ${formatCurrency(ingTransf)})',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              Text('- Retiros: ${formatCurrency(retiros)}'),
              if (retEfec > 0 || retTransf > 0)
                Text('  (Efectivo: ${formatCurrency(retEfec)} • Transf: ${formatCurrency(retTransf)})',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(height: 4),
              Text('TOTAL MOV. EFECTIVO: ${totalMovEfectivoDialog >= 0 ? '+' : ''}${formatCurrency(totalMovEfectivoDialog)}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('(${formatCurrency(ventasEfectivoDialog)} + ${formatCurrency(ingEfec)} - ${formatCurrency(retEfec)})',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(height: 10),
              // CONCILIACIÓN POR MEDIO DE PAGO
              Text('CONCILIACIÓN POR MEDIO DE PAGO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 8),
              Text('EFECTIVO', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              Text('Efectivo esperado: ${formatCurrency(cajaEsperadaDialog)}'),
              Text('Efectivo declarado: ${formatCurrency(eff)}'),
              () {
                final difEfectivo = eff - cajaEsperadaDialog;
                return Text(
                  'Diferencia efectivo: ${difEfectivo >= 0 ? '+' : ''}${formatCurrency(difEfectivo)}',
                  style: TextStyle(
                    color: difEfectivo == 0 ? AppColors.ingreso : (difEfectivo > 0 ? AppColors.info : AppColors.egreso),
                    fontWeight: FontWeight.w700,
                  ),
                );
              }(),
              const SizedBox(height: 8),
              () {
                final difTransf = tr - transfEsperadaDialog;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TRANSFERENCIAS', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    Text('Transf. esperadas: ${formatCurrency(transfEsperadaDialog)}'),
                    if (ingTransf > 0 || retTransf > 0)
                      Text('  (Ventas ${formatCurrency(ventasTransfDialog)} + Ing. ${formatCurrency(ingTransf)} - Ret. ${formatCurrency(retTransf)})',
                          style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                    Text('Transf. declaradas: ${formatCurrency(tr)}'),
                    Text(
                      'Diferencia transf.: ${difTransf >= 0 ? '+' : ''}${formatCurrency(difTransf)}',
                      style: TextStyle(
                        color: difTransf == 0 ? AppColors.ingreso : (difTransf > 0 ? AppColors.info : AppColors.egreso),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                );
              }(),
              const SizedBox(height: 8),
              () {
                final difEf = eff - cajaEsperadaDialog;
                final difTr = tr - transfEsperadaDialog;
                final difTotal = difEf + difTr;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('DIFERENCIA TOTAL DEL EVENTO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                    Text(
                      '${difTotal >= 0 ? '+' : ''}${formatCurrency(difTotal)}',
                      style: TextStyle(
                        fontSize: 16,
                        color: difTotal == 0 ? AppColors.ingreso : (difTotal > 0 ? AppColors.info : AppColors.egreso),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text('(Suma de diferencias por medio de pago)',
                        style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                  ],
                );
              }(),
              const SizedBox(height: 10),
              // RESULTADO ECONÓMICO DEL EVENTO
              () {
                final resultadoNetoDialog = ventasEfectivoDialog + ventasTransfDialog + ingresos - retiros - fondo;
                // Diferencias por medio de pago (con desglose de movimientos)
                final difEfDialog = eff - cajaEsperadaDialog;
                final difTrDialog = tr - transfEsperadaDialog;
                final resultadoConDifDialog = resultadoNetoDialog + difEfDialog + difTrDialog;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('RESULTADO ECONÓMICO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('Ventas en efectivo:       ${formatCurrency(ventasEfectivoDialog)}'),
                    Text('Ventas por transferencia: ${formatCurrency(ventasTransfDialog)}'),
                    Text('Otros ingresos:           ${formatCurrency(ingresos)}'),
                    Text('Retiros:                 (${formatCurrency(retiros)})'),
                    Text('Saldo inicial caja:      (${formatCurrency(fondo)})'),
                    Text('RESULTADO NETO: ${formatCurrency(resultadoNetoDialog)}',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text('(${formatCurrency(ventasEfectivoDialog)} + ${formatCurrency(ventasTransfDialog)} + ${formatCurrency(ingresos)} - ${formatCurrency(retiros)} - ${formatCurrency(fondo)})',
                        style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                    const SizedBox(height: 8),
                    Text('RESULTADO NETO + DIFERENCIAS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      'Dif. efectivo: ${difEfDialog >= 0 ? '+' : ''}${formatCurrency(difEfDialog)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: difEfDialog == 0 ? AppColors.ingreso : (difEfDialog > 0 ? AppColors.info : AppColors.egreso),
                      ),
                    ),
                    Text(
                      'Dif. transferencias: ${difTrDialog >= 0 ? '+' : ''}${formatCurrency(difTrDialog)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: difTrDialog == 0 ? AppColors.ingreso : (difTrDialog > 0 ? AppColors.info : AppColors.egreso),
                      ),
                    ),
                    Text('TOTAL: ${formatCurrency(resultadoConDifDialog)}',
                        style: TextStyle(fontWeight: FontWeight.w900, color: resultadoConDifDialog >= 0 ? AppColors.ingreso : AppColors.egreso)),
                    Text('(${formatCurrency(resultadoNetoDialog)} + ${formatCurrency(difEfDialog)} + ${formatCurrency(difTrDialog)})',
                        style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                  ],
                );
              }(),
              const SizedBox(height: 8),
              Text('Entradas vendidas: ${entradas == null ? '-' : entradas}'),
              Text('Tickets vendidos: $ticketsVendidos'),
              Text('Tickets anulados: $ticketsAnulados'),
              const SizedBox(height: 8),
              const Text('¿Deseás cerrar la caja?'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cerrar caja')),
        ],
      ),
    );
    if (ok != true) return;

    await _svc.cerrarCaja(
      cajaId: _caja!['id'] as int,
      efectivoEnCaja: eff,
      transferencias: tr,
      usuarioCierre: _usuario.text.trim(),
      observacion: _obs.text.trim().isEmpty ? null : _obs.text.trim(),
      entradas: entradas,
    );

    // 1) Intentar imprimir por USB; si no hay impresora, mostrar mensaje
    try {
      final connected = await UsbPrinterService().isConnected();
      if (!connected) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No hay impresora USB conectada.')),
          );
        }
      } else {
        final usbOk =
            await PrintService().printCajaResumenUsbOnly(_caja!['id'] as int);
        if (!usbOk && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo imprimir por USB.')),
          );
        }
      }
    } catch (e, st) {
      AppDatabase.logLocalError(
          scope: 'caja_page.usb_print',
          error: e,
          stackTrace: st,
          payload: {'cajaId': _caja!['id']});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al imprimir: $e')),
        );
      }
    }

    // 2) Guardar automáticamente el PDF y abrir previsualización
    try {
      final file =
          await PrintService().saveCajaResumenPdfFile(_caja!['id'] as int);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF guardado: ${file.path}')),
        );
      }
      await Printing.layoutPdf(
        onLayout: (format) =>
            PrintService().buildCajaResumenPdf(_caja!['id'] as int),
        name: 'cierre_caja_${_caja!['id']}.pdf',
      );
    } catch (e, st) {
      AppDatabase.logLocalError(
          scope: 'caja_page.save_preview_pdf',
          error: e,
          stackTrace: st,
          payload: {'cajaId': _caja!['id']});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo generar/abrir el PDF: $e')),
        );
      }
    }

    if (!context.mounted) return;

    final fecha = (_caja?['fecha'] ?? '').toString().trim();
    final disciplina = (_caja?['disciplina'] ?? '').toString().trim();

    // Mantener HomePage como raíz y luego abrir el Detalle del Evento.
    // Esto evita que el botón "atrás" cierre la app.
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomePage()),
      (route) => false,
    );

    if (fecha.isNotEmpty && disciplina.isNotEmpty) {
      Future.microtask(() {
        nav.push(
          MaterialPageRoute(
            builder: (_) => DetalleEventoPage(
              fecha: fecha,
              disciplina: disciplina,
            ),
          ),
        );
      });
    } else {
      AppDatabase.logLocalError(
        scope: 'caja_page.redirect_detalle_evento',
        error:
            'No se pudo redirigir al detalle del evento (fecha/disciplina vacías)',
        payload: {
          'cajaId': _caja?['id'],
          'fecha': fecha,
          'disciplina': disciplina,
        },
      );
    }
  }

  Future<void> _mostrarDialogoObsPostCierre() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final currentObs = ((_caja?['obs_post_cierre'] as String?) ?? '').trim();
    final controller = TextEditingController(text: currentObs);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Observación post-cierre'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Ingresá la observación...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (ok != true || !mounted) return;

    try {
      await _svc.guardarObsPostCierre(
        cajaId: cajaId,
        observacion: controller.text,
      );
      await _load();
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Observación guardada correctamente')),
        );
      }
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'caja_page.guardar_obs_post_cierre',
        error: e.toString(),
        stackTrace: st,
        payload: {'cajaId': cajaId},
      );
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No se pudo guardar la observación. Intentá nuevamente.'),
            backgroundColor: AppColors.egreso,
          ),
        );
      }
    }
  }

  Future<void> _previewCajaPdf() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;

    await Printing.layoutPdf(
      onLayout: (format) => PrintService().buildCajaResumenPdf(cajaId),
      name: 'cierre_caja_$cajaId.pdf',
    );
  }

  Future<void> _mostrarModalExportarCompartir() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;

    if (!mounted) return;
    final opcion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.description, color: AppColors.ingreso, size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Text('Archivo de cierre de caja')),
          ],
        ),
        content: const Text(
          '¿Qué desea hacer con el archivo Excel del cierre de caja?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'descargar'),
            icon: const Icon(Icons.download),
            label: const Text('Descargar'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'compartir'),
            icon: const Icon(Icons.share),
            label: const Text('Compartir'),
          ),
        ],
      ),
    );

    if (opcion == null || !mounted) return;

    if (opcion == 'descargar') {
      await _exportCajaExcel();
    } else if (opcion == 'compartir') {
      await _compartirCajaExcel();
    }
  }

  Future<void> _compartirCajaExcel() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      final savedPath = await ExportService().exportCajaExcel(cajaId);

      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(savedPath)],
          subject: 'Cierre de caja - Excel',
          title: 'Cierre de caja - Excel',
        ),
      );
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'caja_page.compartir_excel',
        error: e.toString(),
        stackTrace: stack,
        payload: {'cajaId': cajaId},
      );

      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Error al compartir el archivo Excel. Intente nuevamente.'),
          backgroundColor: AppColors.egreso,
        ),
      );
    }
  }

  Future<void> _exportCajaExcel() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      final savedPath = await ExportService().exportCajaExcel(cajaId);

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.check_circle, color: AppColors.ingreso, size: 32),
              const SizedBox(width: 12),
              const Expanded(child: Text('Excel generado')),
            ],
          ),
          content: Text(
            'El archivo se guardó correctamente.\n\nUbicación: $savedPath',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await OpenFilex.open(savedPath);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Abrir archivo'),
            ),
          ],
        ),
      );
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'caja_page.export_excel',
        error: e.toString(),
        stackTrace: stack,
        payload: {'cajaId': cajaId},
      );

      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Error al exportar a Excel. Intente nuevamente.'),
          backgroundColor: AppColors.egreso,
        ),
      );
    }
  }

  Future<void> _printCajaConDecision() async {
    final cajaId = _cajaId;
    if (cajaId == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final usb = UsbPrinterService();
    try {
      final connected = await usb.isConnected();
      if (!connected) {
        if (!context.mounted) return;
        await _mostrarDialogoImpresionFallback();
        return;
      }
      final ok = await PrintService().printCajaResumenUsbOnly(cajaId);
      if (!ok) {
        if (!context.mounted) return;
        await _mostrarDialogoImpresionFallback();
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Error al imprimir: $e')),
      );
    }
  }

  Future<void> _mostrarDialogoImpresionFallback() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Impresora no disponible'),
        content: const Text(
            '¿Querés ir a Configurar impresora o ver Previsualización PDF?'),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _previewCajaPdf();
            },
            child: const Text('Previsualización PDF'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PrinterTestPage()),
              );
              if (!mounted) return;
              setState(() {});
            },
            child: const Text('Config impresora'),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String estado;
  final String fecha;
  final String hora;
  final String codigoCaja;
  final String? syncEstado;
  final String? syncLastError;
  const _StatusCard(
      {required this.estado,
      required this.fecha,
      required this.hora,
      required this.codigoCaja,
      this.syncEstado,
      this.syncLastError});

  @override
  Widget build(BuildContext context) {
    final isAbierta = estado.toUpperCase().contains('ABIERTA');
    final color =
        isAbierta ? AppColors.ingreso : Theme.of(context).colorScheme.secondary;

    final sync = (syncEstado ?? '').trim().toUpperCase();
    final hasSync = sync.isNotEmpty;
    final syncColor = (sync == 'SINCRONIZADA')
        ? AppColors.ingreso
        : (sync == 'ERROR')
            ? AppColors.egreso
            : Theme.of(context).colorScheme.secondary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Estado Actual',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      estado.toUpperCase(),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.check_circle, size: 16, color: color),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  codigoCaja,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasSync) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Sync: $sync',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: syncColor,
                          fontWeight: FontWeight.w700,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (sync == 'ERROR' && (syncLastError ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      (syncLastError ?? '').trim(),
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(fecha, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 2),
              Text(
                hora.isEmpty ? '—' : '$hora HS',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalVentasCard extends StatelessWidget {
  final double total;
  final double efectivo;
  final double transferencia;
  const _TotalVentasCard(
      {required this.total,
      required this.efectivo,
      required this.transferencia});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total Vendido',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            formatCurrency(total),
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Efectivo',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.white70)),
                    const SizedBox(height: 2),
                    Text(
                      formatCurrency(efectivo),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Transferencia',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.white70)),
                    const SizedBox(height: 2),
                    Text(
                      formatCurrency(transferencia),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatefulWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final bool initiallyExpanded;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.initiallyExpanded = true,
  });

  @override
  State<_SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<_SectionCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.6)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            Material(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Icon(widget.icon,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title.toUpperCase(),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8),
                        ),
                      ),
                      if (widget.trailing != null) ...[
                        widget.trailing!,
                        const SizedBox(width: 8),
                      ],
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 22,
                        color: Theme.of(context).hintColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(padding: const EdgeInsets.all(14), child: widget.child),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}

Widget _kv(String k, String v, {bool italicValue = false}) {
  return Builder(
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).hintColor)),
        const SizedBox(height: 2),
        Text(
          v,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontStyle: italicValue ? FontStyle.italic : FontStyle.normal,
                color: italicValue ? Theme.of(context).hintColor : null,
              ),
        ),
      ],
    ),
  );
}

Widget _kvRow(BuildContext context, String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

Widget _movementRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required String value,
  TextStyle? valueStyle,
}) {
  return Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Theme.of(context).colorScheme.primary),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).hintColor)),
          ],
        ),
      ),
      Text(value,
          style: valueStyle ??
              Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
    ],
  );
}
