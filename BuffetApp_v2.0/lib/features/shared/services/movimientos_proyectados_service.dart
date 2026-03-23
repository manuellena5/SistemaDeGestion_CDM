import '../../../data/dao/db.dart';
import '../../../data/dao/evento_dao.dart';
import 'compromisos_service.dart';

/// FASE 13.5: Servicio para calcular movimientos esperados dinámicamente.
///
/// Responsabilidades:
/// - Calcular movimientos proyectados a partir de compromisos activos
/// - Generar vencimientos según frecuencia
/// - Filtrar por rango de fechas
/// - Excluir vencimientos ya confirmados o cancelados
/// - Retornar objetos en memoria (NO insertar en DB)
///
/// Reglas:
/// - Solo compromisos activos (activo=1, eliminado=0)
/// - Respetar fecha_fin y cuotas
/// - No duplicar vencimientos ya confirmados
/// - Los movimientos ESPERADOS son transitorios (no se persisten)
class MovimientosProyectadosService {
  MovimientosProyectadosService._();
  static final instance = MovimientosProyectadosService._();

  final _compromisosService = CompromisosService.instance;

  /// Calcula todos los movimientos esperados de un compromiso en un rango de fechas.
  ///
  /// FASE 13.5: Ahora lee desde la tabla compromiso_cuotas en lugar de calcular on-the-fly.
  ///
  /// Parámetros:
  /// - [compromisoId]: ID del compromiso
  /// - [fechaDesde]: fecha inicial del rango (inclusive)
  /// - [fechaHasta]: fecha final del rango (inclusive)
  ///
  /// Retorna lista de movimientos proyectados (objetos en memoria).
  ///
  /// Lógica:
  /// 1. Obtener datos del compromiso
  /// 2. Validar que esté activo
  /// 3. Leer cuotas desde compromiso_cuotas
  /// 4. Filtrar por rango de fechas
  /// 5. Solo mostrar cuotas con estado 'ESPERADO'
  ///
  /// Retorna lista vacía si:
  /// - Compromiso no existe o está pausado/eliminado
  /// - No hay cuotas en el rango
  /// - Todas las cuotas están confirmadas o canceladas
  Future<List<MovimientoProyectado>> calcularMovimientosEsperados({
    required int compromisoId,
    required DateTime fechaDesde,
    required DateTime fechaHasta,
  }) async {
    try {
      final compromiso = await _compromisosService.obtenerCompromiso(compromisoId);
      if (compromiso == null || compromiso['activo'] != 1) {
        return [];
      }

      final db = await AppDatabase.instance();

      final tipo = compromiso['tipo'] as String;
      final categoria = compromiso['categoria'] as String;
      final nombre = compromiso['nombre'] as String;
      final observaciones = compromiso['observaciones'] as String?;
      final unidadGestionId = compromiso['unidad_gestion_id'] as int;
      final totalCuotas = compromiso['cuotas'] as int?;
      final entidadNombre = compromiso['entidad_nombre'] as String?;

      // Obtener unidad del acuerdo (ARS o LTS) si el compromiso viene de un acuerdo
      String unidadAcuerdo = 'ARS';
      final acuerdoIdComp = compromiso['acuerdo_id'];
      if (acuerdoIdComp != null) {
        final acuerdos = await db.query(
          'acuerdos',
          columns: ['unidad'],
          where: 'id = ?',
          whereArgs: [acuerdoIdComp],
          limit: 1,
        );
        if (acuerdos.isNotEmpty) {
          unidadAcuerdo = (acuerdos.first['unidad'] as String?) ?? 'ARS';
        }
      }

      final cuotas = await db.query(
        'compromiso_cuotas',
        where: 'compromiso_id = ? AND estado = ?',
        whereArgs: [compromisoId, 'ESPERADO'],
        orderBy: 'numero_cuota',
      );

      final vencimientos = <MovimientoProyectado>[];
      
      for (final cuota in cuotas) {
        final fechaStr = cuota['fecha_programada'] as String;
        final fechaVencimiento = DateTime.parse(fechaStr);
        
        if (fechaVencimiento.isBefore(fechaDesde) || fechaVencimiento.isAfter(fechaHasta)) {
          continue;
        }
        
        vencimientos.add(MovimientoProyectado(
          compromisoId: compromisoId,
          fechaVencimiento: fechaVencimiento,
          monto: (cuota['monto_esperado'] as num).toDouble(),
          numeroCuota: cuota['numero_cuota'] as int,
          totalCuotas: totalCuotas,
          tipo: tipo,
          categoria: categoria,
          nombre: nombre,
          observaciones: observaciones,
          unidadGestionId: unidadGestionId,
          entidadNombre: entidadNombre,
          unidadAcuerdo: unidadAcuerdo,
        ));
      }

      return vencimientos;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_esperados',
        error: e,
        stackTrace: st,
        payload: {'compromiso': compromisoId},
      );
      rethrow;
    }
  }

  /// Calcula movimientos esperados de todos los compromisos activos en un rango.
  ///
  /// Parámetros:
  /// - [fechaDesde]: fecha inicial (inclusive)
  /// - [fechaHasta]: fecha final (inclusive)
  /// - [unidadGestionId]: filtrar por unidad de gestión (opcional)
  /// - [tipo]: filtrar por INGRESO o EGRESO (opcional)
  ///
  /// Retorna lista de movimientos proyectados ordenados por fecha.
  Future<List<MovimientoProyectado>> calcularMovimientosEsperadosGlobal({
    required DateTime fechaDesde,
    required DateTime fechaHasta,
    int? unidadGestionId,
    String? tipo,
  }) async {
    try {
      final compromisos = await _compromisosService.listarCompromisos(
        unidadGestionId: unidadGestionId,
        tipo: tipo,
        activo: true,
      );

      final todosMovimientos = <MovimientoProyectado>[];

      for (final compromiso in compromisos) {
        final id = compromiso['id'] as int;
        final movimientos = await calcularMovimientosEsperados(
          compromisoId: id,
          fechaDesde: fechaDesde,
          fechaHasta: fechaHasta,
        );
        todosMovimientos.addAll(movimientos);
      }

      todosMovimientos.sort((a, b) => a.fechaVencimiento.compareTo(b.fechaVencimiento));

      return todosMovimientos;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_global',
        error: e,
        stackTrace: st,
        payload: {'unidad': unidadGestionId, 'tipo': tipo},
      );
      rethrow;
    }
  }

  /// Calcula movimientos esperados para un mes específico.
  ///
  /// Incluye automáticamente los esperados POR_EVENTO: un item esperado por
  /// cada (acuerdo POR_EVENTO × partido del mes) que no tenga aún un
  /// movimiento confirmado.
  Future<List<MovimientoProyectado>> calcularMovimientosEsperadosMes({
    required int year,
    required int month,
    int? unidadGestionId,
    String? tipo,
  }) async {
    try {
      final fechaDesde = DateTime(year, month, 1);
      final fechaHasta = DateTime(year, month + 1, 1).subtract(const Duration(days: 1));

      final regulares = await calcularMovimientosEsperadosGlobal(
        fechaDesde: fechaDesde,
        fechaHasta: fechaHasta,
        unidadGestionId: unidadGestionId,
        tipo: tipo,
      );

      // Agregar esperados POR_EVENTO si hay una unidad de gestión activa
      final porEvento = unidadGestionId != null
          ? await calcularMovimientosPorEventoMes(
              year: year,
              month: month,
              unidadGestionId: unidadGestionId,
              tipo: tipo,
            )
          : <MovimientoProyectado>[];

      final resultado = [...regulares, ...porEvento];
      resultado.sort((a, b) => a.fechaVencimiento.compareTo(b.fechaVencimiento));
      return resultado;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_mes',
        error: e,
        stackTrace: st,
        payload: {'year': year, 'month': month, 'unidad': unidadGestionId},
      );
      rethrow;
    }
  }

  /// Calcula movimientos esperados para acuerdos POR_EVENTO en un mes.
  ///
  /// Genera un [MovimientoProyectado] por cada combinación
  /// (acuerdo POR_EVENTO activo × partido del mes) que no tenga aún un
  /// movimiento confirmado (`evento_movimiento` con acuerdo_id + evento_cdm_id).
  Future<List<MovimientoProyectado>> calcularMovimientosPorEventoMes({
    required int year,
    required int month,
    required int unidadGestionId,
    String? tipo,
  }) async {
    try {
      final db = await AppDatabase.instance();
      final anioMes = '$year-${month.toString().padLeft(2, '0')}';

      // 1. Acuerdos POR_EVENTO activos de la unidad
      final acuerdos = await EventoDao.getAcuerdosPorPartido(unidadGestionId);
      if (acuerdos.isEmpty) return [];

      // 2. Partidos del mes para esa unidad
      final partidos = await EventoDao.getEventosByMes(unidadGestionId, anioMes);
      final partidosDelMes = partidos.where((e) => e['tipo'] == 'PARTIDO').toList();
      if (partidosDelMes.isEmpty) return [];

      final resultado = <MovimientoProyectado>[];

      for (final acuerdo in acuerdos) {
        final acuerdoId = acuerdo['id'] as int;
        final acuerdoTipo = acuerdo['tipo'] as String? ?? 'EGRESO';
        final acuerdoCategoria = acuerdo['categoria'] as String? ?? 'OTROS';
        final acuerdoNombre = acuerdo['nombre'] as String? ?? 'Acuerdo #$acuerdoId';
        final montoTitular = (acuerdo['monto_titular'] as num?)?.toDouble() ?? 0.0;
        final unidadGestionIdAcuerdo = acuerdo['unidad_gestion_id'] as int;
        final entidadNombre = acuerdo['entidad_nombre'] as String?;

        // Filtrar por tipo si se especificó
        if (tipo != null && acuerdoTipo != tipo) continue;

        for (final partido in partidosDelMes) {
          final eventoId = partido['id'] as int;
          final eventoFecha = partido['fecha'] as String? ?? anioMes;
          final eventoTitulo = partido['titulo'] as String? ?? 'Partido';

          // Verificar si ya existe un movimiento confirmado para este par
          final existentes = await db.rawQuery('''
            SELECT COUNT(*) as cnt FROM evento_movimiento
            WHERE acuerdo_id = ? AND evento_cdm_id = ?
              AND eliminado = 0 AND estado = 'CONFIRMADO'
          ''', [acuerdoId, eventoId]);
          final yaConfirmado = (existentes.first['cnt'] as int? ?? 0) > 0;
          if (yaConfirmado) continue;

          resultado.add(MovimientoProyectado(
            compromisoId: 0, // No hay compromiso real
            acuerdoId: acuerdoId,
            eventoCdmId: eventoId,
            fechaVencimiento: DateTime.tryParse(eventoFecha) ?? DateTime(year, month, 1),
            monto: montoTitular,
            numeroCuota: null,
            tipo: acuerdoTipo,
            categoria: acuerdoCategoria,
            nombre: '$acuerdoNombre — $eventoTitulo',
            unidadGestionId: unidadGestionIdAcuerdo,
            entidadNombre: entidadNombre,
          ));
        }
      }

      return resultado;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_por_evento_mes',
        error: e,
        stackTrace: st,
        payload: {'year': year, 'month': month, 'unidad': unidadGestionId},
      );
      return []; // Error no crítico: devolver lista vacía
    }
  }


  /// Calcula movimientos cancelados para un mes específico.
  ///
  /// Parámetros:
  /// - [year]: año
  /// - [month]: mes (1-12)
  /// - [unidadGestionId]: filtrar por unidad (opcional)
  /// - [tipo]: filtrar por INGRESO/EGRESO (opcional)
  ///
  /// Retorna movimientos cancelados del mes (según su fecha programada original).
  Future<List<MovimientoProyectado>> calcularMovimientosCanceladosMes({
    required int year,
    required int month,
    int? unidadGestionId,
    String? tipo,
  }) async {
    try {
      final fechaDesde = DateTime(year, month, 1);
      final fechaHasta = DateTime(year, month + 1, 1).subtract(const Duration(days: 1));

      final compromisos = await _compromisosService.listarCompromisos(
        unidadGestionId: unidadGestionId,
        tipo: tipo,
        activo: true,
      );

      final db = await AppDatabase.instance();
      final todosCancelados = <MovimientoProyectado>[];

      for (final compromiso in compromisos) {
        final compromisoId = compromiso['id'] as int;
        final tipoComp = compromiso['tipo'] as String;
        final categoria = compromiso['categoria'] as String;
        final nombre = compromiso['nombre'] as String;
        final observaciones = compromiso['observaciones'] as String?;
        final unidadGestionIdComp = compromiso['unidad_gestion_id'] as int;
        final totalCuotas = compromiso['cuotas'] as int?;
        final entidadNombre = compromiso['entidad_nombre'] as String?;

        final cuotas = await db.query(
          'compromiso_cuotas',
          where: 'compromiso_id = ? AND estado = ?',
          whereArgs: [compromisoId, 'CANCELADO'],
          orderBy: 'numero_cuota',
        );

        for (final cuota in cuotas) {
          final fechaStr = cuota['fecha_programada'] as String;
          final fechaVencimiento = DateTime.parse(fechaStr);
          
          if (fechaVencimiento.isBefore(fechaDesde) || fechaVencimiento.isAfter(fechaHasta)) {
            continue;
          }
          
          todosCancelados.add(MovimientoProyectado(
            compromisoId: compromisoId,
            fechaVencimiento: fechaVencimiento,
            monto: (cuota['monto_esperado'] as num).toDouble(),
            numeroCuota: cuota['numero_cuota'] as int,
            totalCuotas: totalCuotas,
            tipo: tipoComp,
            categoria: categoria,
            nombre: nombre,
            observaciones: observaciones,
            unidadGestionId: unidadGestionIdComp,
            estado: 'CANCELADO',
            entidadNombre: entidadNombre,
          ));
        }
      }

      todosCancelados.sort((a, b) => a.fechaVencimiento.compareTo(b.fechaVencimiento));

      return todosCancelados;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_cancelados_mes',
        error: e,
        stackTrace: st,
        payload: {'year': year, 'month': month, 'unidad': unidadGestionId},
      );
      rethrow;
    }
  }

  /// Calcula el total esperado (suma de montos) en un rango de fechas.
  ///
  /// Útil para mostrar proyecciones en UI.
  Future<Map<String, double>> calcularTotalEsperado({
    required DateTime fechaDesde,
    required DateTime fechaHasta,
    int? unidadGestionId,
  }) async {
    try {
      final movimientos = await calcularMovimientosEsperadosGlobal(
        fechaDesde: fechaDesde,
        fechaHasta: fechaHasta,
        unidadGestionId: unidadGestionId,
      );

      double totalIngresos = 0;
      double totalEgresos = 0;

      for (final mov in movimientos) {
        if (mov.tipo == 'INGRESO') {
          totalIngresos += mov.monto;
        } else {
          totalEgresos += mov.monto;
        }
      }

      return {
        'ingresos': totalIngresos,
        'egresos': totalEgresos,
        'saldo': totalIngresos - totalEgresos,
      };
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.calcular_total_esperado',
        error: e,
        stackTrace: st,
        payload: {'unidad': unidadGestionId},
      );
      rethrow;
    }
  }

  /// Verifica si un compromiso tiene movimientos esperados pendientes.
  Future<bool> tieneMovimientosEsperados({
    required int compromisoId,
    DateTime? fechaDesde,
  }) async {
    try {
      final desde = fechaDesde ?? DateTime.now();
      final hasta = DateTime(2099, 12, 31);

      final movimientos = await calcularMovimientosEsperados(
        compromisoId: compromisoId,
        fechaDesde: desde,
        fechaHasta: hasta,
      );

      return movimientos.isNotEmpty;
    } catch (e, st) {
      await AppDatabase.logLocalError(
        scope: 'mov_proyectados.tiene_esperados',
        error: e,
        stackTrace: st,
        payload: {'compromiso': compromisoId},
      );
      rethrow;
    }
  }
}

/// Modelo transient para movimientos proyectados.
///
/// NO se persiste en DB, solo se usa para cálculos y visualización.
class MovimientoProyectado {
  final int compromisoId;
  final DateTime fechaVencimiento;
  final double monto;
  final int? numeroCuota; // null si el compromiso no tiene cuotas
  final int? totalCuotas; // total de cuotas del compromiso (para mostrar X/Y)
  final String tipo; // 'INGRESO' | 'EGRESO'
  final String categoria;
  final String nombre;
  final String? observaciones;
  final int unidadGestionId;
  final String estado; // 'ESPERADO' | 'CANCELADO'
  final String? entidadNombre; // Nombre del jugador/staff asociado
  final String unidadAcuerdo; // 'ARS' | 'LTS'
  // Campos exclusivos de movimientos POR_EVENTO (compromisoId = 0)
  final int? acuerdoId;
  final int? eventoCdmId;

  /// Un MovimientoProyectado es POR_EVENTO cuando compromisoId = 0 y
  /// acuerdoId != null. La acción de confirmar abre CrearMovimientoPage.
  bool get esPorEvento => compromisoId == 0 && acuerdoId != null;

  const MovimientoProyectado({
    required this.compromisoId,
    required this.fechaVencimiento,
    required this.monto,
    required this.numeroCuota,
    this.totalCuotas,
    required this.tipo,
    required this.categoria,
    required this.nombre,
    this.observaciones,
    required this.unidadGestionId,
    this.estado = 'ESPERADO',
    this.entidadNombre,
    this.unidadAcuerdo = 'ARS',
    this.acuerdoId,
    this.eventoCdmId,
  });

  /// Convierte a Map para fácil integración con UI.
  Map<String, dynamic> toMap() {
    return {
      'compromiso_id': compromisoId,
      'fecha_vencimiento': fechaVencimiento.toIso8601String(),
      'monto': monto,
      'numero_cuota': numeroCuota,
      'total_cuotas': totalCuotas,
      'tipo': tipo,
      'categoria': categoria,
      'nombre': nombre,
      'observaciones': observaciones,
      'unidad_gestion_id': unidadGestionId,
      'estado': estado,
      'entidad_nombre': entidadNombre,
      'unidad_acuerdo': unidadAcuerdo,
      'acuerdo_id': acuerdoId,
      'evento_cdm_id': eventoCdmId,
    };
  }

  /// Genera descripción para mostrar en UI.
  String get descripcion {
    final cuotaStr = numeroCuota != null && totalCuotas != null
        ? ' (Cuota $numeroCuota/$totalCuotas)'
        : numeroCuota != null
        ? ' (Cuota $numeroCuota)'
        : '';
    return '$nombre$cuotaStr';
  }

  @override
  String toString() {
    return 'MovimientoProyectado(compromiso=$compromisoId, fecha=$fechaVencimiento, monto=$monto, cuota=$numeroCuota, estado=$estado)';
  }
}
