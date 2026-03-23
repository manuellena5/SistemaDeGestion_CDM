import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../../../data/database/app_database.dart';
import '../../shared/services/acuerdos_service.dart';

/// Servicio para importar acuerdos de adhesiones masivamente desde Excel.
class AdhesionImportService {
  static final AdhesionImportService instance = AdhesionImportService._();
  AdhesionImportService._();

  static const subcategoriasValidas = ['Colaboracion', 'Combustible'];

  // ─── Generación de template ───────────────────────────────────────────────

  Future<String> generarTemplate() async {
    final excel = Excel.createExcel();

    // Hoja principal
    final sheet = excel['Adhesiones'];
    sheet.appendRow([
      'Nombre',
      'Subcategoria',
      'Monto',
      'Fecha Inicio',
      'Fecha Fin',
      'Observaciones',
      'Unidad',
    ]);

    // Ejemplo Colaboracion
    sheet.appendRow([
      'Club Atletico Ejemplo',
      'Colaboracion',
      '5000',
      '01/01/2026',
      '31/12/2026',
      'Aporte mensual voluntario',
      'Dinero',
    ]);

    // Ejemplo Combustible en litros
    sheet.appendRow([
      'Empresa Combustibles SA',
      'Combustible',
      '100',
      '01/03/2026',
      '',
      'Donación de combustible mensual',
      'Litros',
    ]);

    // Hoja Instrucciones
    final instrSheet = excel['Instrucciones'];
    instrSheet.appendRow(['INSTRUCCIONES DE IMPORTACIÓN — ACUERDOS DE ADHESIÓN']);
    instrSheet.appendRow(['']);
    instrSheet.appendRow(['1. Complete la hoja "Adhesiones" con sus datos']);
    instrSheet.appendRow(['2. Columnas REQUERIDAS: Nombre, Subcategoria, Monto, Fecha Inicio']);
    instrSheet.appendRow(['3. Columnas OPCIONALES: Fecha Fin, Observaciones, Unidad']);
    instrSheet.appendRow(['4. Subcategorías válidas: Colaboracion, Combustible']);
    instrSheet.appendRow(['5. Fechas en formato dd/mm/yyyy  (ej: 01/03/2026)']);
    instrSheet.appendRow(['6. Fecha Fin puede quedar vacía (acuerdo sin vencimiento)']);
    instrSheet.appendRow(['7. Unidad: "Dinero" o "Litros" (solo relevante para Combustible; default Dinero)']);
    instrSheet.appendRow(['8. Monto debe ser un número positivo (ej: 5000 o 100.50)']);
    instrSheet.appendRow(['9. Los acuerdos se crean con frecuencia MENSUAL, tipo INGRESO']);
    instrSheet.appendRow(['10. Se genera un compromiso por mes entre Fecha Inicio y Fecha Fin']);
    instrSheet.appendRow(['']);
    instrSheet.appendRow(['NOTAS:']);
    instrSheet.appendRow(['- Si ya existe una adhesión con el mismo nombre, se mostrará una advertencia']);
    instrSheet.appendRow(['- No elimine ni modifique la fila de encabezados (fila 1)']);
    instrSheet.appendRow(['- Puede dejar filas en blanco entre datos (serán ignoradas)']);

    // Hoja Valores Válidos
    final valSheet = excel['Valores Válidos'];
    valSheet.appendRow(['CAMPO', 'VALORES VÁLIDOS', 'DESCRIPCIÓN']);
    valSheet.appendRow(['Subcategoria', 'Colaboracion', 'Aporte económico en dinero']);
    valSheet.appendRow(['Subcategoria', 'Combustible', 'Aporte en combustible (Dinero o Litros)']);
    valSheet.appendRow(['Unidad', 'Dinero', 'El monto es en pesos ARS (valor por defecto)']);
    valSheet.appendRow(['Unidad', 'Litros', 'El monto es en litros de combustible']);
    valSheet.appendRow(['Fecha', 'dd/mm/yyyy', 'Ejemplo: 01/03/2026']);

    final tempDir = await getTemporaryDirectory();
    final fileName = 'adhesiones_template_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final filePath = path.join(tempDir.path, fileName);
    final file = File(filePath);
    await file.writeAsBytes(excel.encode()!);
    return filePath;
  }

  // ─── Lectura y parsing del Excel ─────────────────────────────────────────

  Future<Map<String, dynamic>> leerArchivoExcel(String filePath) async {
    final filas = <Map<String, dynamic>>[];
    final erroresGlobales = <String>[];

    try {
      final bytes = await File(filePath).readAsBytes();
      final excel = Excel.decodeBytes(bytes);

      // Buscar hoja "Adhesiones" (case-insensitive), sino usar primera
      final sheetName = excel.tables.keys.firstWhere(
        (n) => n.toLowerCase().contains('adhesion'),
        orElse: () => excel.tables.keys.first,
      );

      final sheet = excel.tables[sheetName];
      if (sheet == null || sheet.rows.isEmpty) {
        erroresGlobales.add('No se encontraron datos en el archivo.');
        return {'filas': filas, 'erroresGlobales': erroresGlobales, 'nombresEnDB': <String>{}};
      }

      // Detectar fila de encabezados buscando "nombre" en la primera columna
      int headerRow = -1;
      final Map<String, int> cols = {};

      for (int i = 0; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final firstCell = _cellToString(row.elementAtOrNull(0)?.value).toLowerCase();
        if (firstCell == 'nombre') {
          headerRow = i;
          for (int j = 0; j < row.length; j++) {
            final h = _cellToString(row.elementAtOrNull(j)?.value).toLowerCase().trim();
            if (h == 'nombre') {
              cols['nombre'] = j;
            } else if (h == 'subcategoria' || h == 'subcategoría') {
              cols['subcategoria'] = j;
            } else if (h == 'monto') {
              cols['monto'] = j;
            } else if (h.contains('inicio')) {
              cols['fecha_inicio'] = j;
            } else if (h.contains('fin')) {
              cols['fecha_fin'] = j;
            } else if (h.contains('observ')) {
              cols['observaciones'] = j;
            } else if (h == 'unidad') {
              cols['unidad'] = j;
            }
          }
          break;
        }
      }

      if (headerRow == -1) {
        erroresGlobales.add('No se encontraron encabezados. Verificá que la primera columna sea "Nombre".');
        return {'filas': filas, 'erroresGlobales': erroresGlobales, 'nombresEnDB': <String>{}};
      }

      final requiredCols = ['nombre', 'subcategoria', 'monto', 'fecha_inicio'];
      final missing = requiredCols.where((c) => !cols.containsKey(c)).toList();
      if (missing.isNotEmpty) {
        erroresGlobales.add('Faltan columnas requeridas: ${missing.join(', ')}. '
            'Verificá que el archivo tenga: Nombre, Subcategoria, Monto, Fecha Inicio.');
        return {'filas': filas, 'erroresGlobales': erroresGlobales, 'nombresEnDB': <String>{}};
      }

      // Nombres existentes para detección de duplicados
      final db = await AppDatabase.instance();
      final existentes = await db.query(
        'acuerdos',
        columns: ['nombre'],
        where: 'es_adhesion = 1 AND eliminado = 0',
      );
      final nombresEnDB = existentes
          .map((r) => (r['nombre'] as String).toLowerCase().trim())
          .toSet();

      // Parsear filas de datos
      int filaNum = 0;
      for (int i = headerRow + 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];

        // Saltar filas completamente vacías
        if (row.every((c) => c?.value == null || _cellToString(c?.value).isEmpty)) {
          continue;
        }

        filaNum++;
        final erroresFila = <String>[];

        final rawNombre = _cellToString(row.elementAtOrNull(cols['nombre']!)?.value);
        final rawSubcat = _cellToString(row.elementAtOrNull(cols['subcategoria']!)?.value);
        final rawMonto = _cellToString(row.elementAtOrNull(cols['monto']!)?.value);
        final rawFechaInicio = _cellToFechaString(row.elementAtOrNull(cols['fecha_inicio']!)?.value);
        final rawFechaFin = cols.containsKey('fecha_fin')
            ? _cellToFechaString(row.elementAtOrNull(cols['fecha_fin']!)?.value)
            : '';
        final rawObs = cols.containsKey('observaciones')
            ? _cellToString(row.elementAtOrNull(cols['observaciones']!)?.value)
            : '';
        final rawUnidad = cols.containsKey('unidad')
            ? _cellToString(row.elementAtOrNull(cols['unidad']!)?.value)
            : '';

        // Validar nombre
        if (rawNombre.isEmpty) erroresFila.add('Nombre vacío');

        // Validar subcategoria
        String subcategoria = '';
        if (rawSubcat.isEmpty) {
          erroresFila.add('Subcategoria vacía (use Colaboracion o Combustible)');
        } else {
          final normalizado = subcategoriasValidas.firstWhere(
            (s) => s.toLowerCase() == rawSubcat.toLowerCase(),
            orElse: () => '',
          );
          if (normalizado.isEmpty) {
            erroresFila.add('Subcategoria "$rawSubcat" no válida (use Colaboracion o Combustible)');
          } else {
            subcategoria = normalizado;
          }
        }

        // Validar monto
        double monto = 0;
        final montoNum = double.tryParse(rawMonto.replaceAll(',', '.'));
        if (rawMonto.isEmpty) {
          erroresFila.add('Monto vacío');
        } else if (montoNum == null || montoNum <= 0) {
          erroresFila.add('Monto "$rawMonto" inválido (debe ser un número mayor a 0)');
        } else {
          monto = montoNum;
        }

        // Validar fecha inicio
        String fechaInicio = '';
        if (rawFechaInicio.isEmpty) {
          erroresFila.add('Fecha Inicio vacía');
        } else {
          fechaInicio = _parseFechaAIso(rawFechaInicio);
          if (fechaInicio.isEmpty) {
            erroresFila.add('Fecha Inicio "$rawFechaInicio" inválida (use dd/mm/yyyy)');
          }
        }

        // Validar fecha fin (opcional)
        String? fechaFin;
        if (rawFechaFin.isNotEmpty) {
          final parsed = _parseFechaAIso(rawFechaFin);
          if (parsed.isEmpty) {
            erroresFila.add('Fecha Fin "$rawFechaFin" inválida (use dd/mm/yyyy)');
          } else {
            fechaFin = parsed;
            if (fechaInicio.isNotEmpty &&
                DateTime.parse(fechaFin).isBefore(DateTime.parse(fechaInicio))) {
              erroresFila.add('Fecha Fin debe ser igual o posterior a Fecha Inicio');
            }
          }
        }

        // Unidad: "Litros" → LTS, cualquier otra cosa → ARS
        final unidad = rawUnidad.toLowerCase() == 'litros' ? 'LTS' : 'ARS';

        // Duplicado de nombre en DB
        final esDuplicado =
            rawNombre.isNotEmpty && nombresEnDB.contains(rawNombre.toLowerCase().trim());

        filas.add({
          'filaExcel': i + 1,   // número de línea real en el Excel
          'filaNum': filaNum,    // índice secuencial entre filas no vacías
          'nombre': rawNombre,
          'subcategoria': subcategoria.isNotEmpty ? subcategoria : rawSubcat,
          'monto': monto,
          'montoRaw': rawMonto,
          'fechaInicio': fechaInicio,
          'fechaInicioRaw': rawFechaInicio,
          'fechaFin': fechaFin,
          'fechaFinRaw': rawFechaFin,
          'observaciones': rawObs,
          'unidad': unidad,
          'esDuplicado': esDuplicado,
          'errores': List<String>.from(erroresFila),
          'valido': erroresFila.isEmpty,
        });
      }

      if (filas.isEmpty) {
        erroresGlobales.add('El archivo no contiene datos de adhesiones (solo encabezados).');
      }

      return {
        'filas': filas,
        'erroresGlobales': erroresGlobales,
        'nombresEnDB': nombresEnDB,
      };
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesion_import.leer_excel',
        error: e.toString(),
        stackTrace: stack,
      );
      return {
        'filas': filas,
        'erroresGlobales': ['Error al leer el archivo: ${e.toString()}'],
        'nombresEnDB': <String>{},
      };
    }
  }

  // ─── Importación ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> importarAdhesiones(
    List<Map<String, dynamic>> filas,
    int unidadGestionId,
  ) async {
    int creados = 0;
    int conAdvertencias = 0;
    final erroresPorFila = <String>[];

    try {
      // Lookup IDs de subcategorias (Colaboracion → id, Combustible → id)
      final subcatIds = await _lookupSubcategoriaIds();

      for (final fila in filas) {
        if (!(fila['valido'] as bool)) continue;

        final nombre = (fila['nombre'] as String).trim();
        final subcatNombre = fila['subcategoria'] as String;
        final monto = (fila['monto'] as num).toDouble();
        final fechaInicio = fila['fechaInicio'] as String;
        final fechaFin = fila['fechaFin'] as String?;
        final obs = (fila['observaciones'] as String).trim();
        final unidad = fila['unidad'] as String;
        final esDuplicado = fila['esDuplicado'] as bool;
        final filaExcel = fila['filaExcel'] as int;

        final subcategoriaId = subcatIds[subcatNombre];

        try {
          await AcuerdosService.crearAcuerdo(
            unidadGestionId: unidadGestionId,
            nombre: nombre,
            tipo: 'INGRESO',
            modalidad: 'RECURRENTE',
            montoPeriodico: monto,
            frecuencia: 'MENSUAL',
            fechaInicio: fechaInicio,
            fechaFin: fechaFin,
            categoria: 'ADHE',
            observaciones: obs.isNotEmpty ? obs : null,
            esAdhesion: true,
            unidad: unidad,
            subcategoriaId: subcategoriaId,
          );
          creados++;
          if (esDuplicado) conAdvertencias++;
        } catch (e, stack) {
          await AppDatabase.logLocalError(
            scope: 'adhesion_import.crear_acuerdo',
            error: e.toString(),
            stackTrace: stack,
            payload: {'filaExcel': filaExcel, 'nombre': nombre},
          );
          erroresPorFila.add('Fila $filaExcel ("$nombre"): ${e.toString()}');
        }
      }

      return {
        'creados': creados,
        'conAdvertencias': conAdvertencias,
        'erroresPorFila': erroresPorFila,
      };
    } catch (e, stack) {
      await AppDatabase.logLocalError(
        scope: 'adhesion_import.importar_adhesiones',
        error: e.toString(),
        stackTrace: stack,
      );
      throw Exception('Error al importar adhesiones: ${e.toString()}');
    }
  }

  // ─── Revalidación (para edición en pantalla) ─────────────────────────────

  /// Revalida una fila editada sin ir a la DB.
  /// [nombresEnDB] es el cache de nombres ya existentes en DB (Set sin mayúsculas).
  Map<String, dynamic> revalidarFila(
    Map<String, dynamic> fila,
    Set<String> nombresEnDB,
  ) {
    final errores = <String>[];
    final nombre = (fila['nombre'] as String? ?? '').trim();
    final subcategoria = (fila['subcategoria'] as String? ?? '').trim();
    final montoRaw = (fila['montoRaw'] as String? ?? '').trim();
    final fechaInicioRaw = (fila['fechaInicioRaw'] as String? ?? '').trim();
    final fechaFinRaw = (fila['fechaFinRaw'] as String? ?? '').trim();
    final unidad = fila['unidad'] as String? ?? 'ARS';

    if (nombre.isEmpty) errores.add('Nombre vacío');

    final normalizado = subcategoriasValidas.firstWhere(
      (s) => s.toLowerCase() == subcategoria.toLowerCase(),
      orElse: () => '',
    );
    if (normalizado.isEmpty && subcategoria.isNotEmpty) {
      errores.add('Subcategoria "$subcategoria" no válida');
    } else if (subcategoria.isEmpty) {
      errores.add('Subcategoria vacía');
    }

    final montoNum = double.tryParse(montoRaw.replaceAll(',', '.'));
    if (montoRaw.isEmpty) {
      errores.add('Monto vacío');
    } else if (montoNum == null || montoNum <= 0) {
      errores.add('Monto inválido');
    }

    String fechaInicio = '';
    if (fechaInicioRaw.isEmpty) {
      errores.add('Fecha Inicio vacía');
    } else {
      fechaInicio = _parseFechaAIso(fechaInicioRaw);
      if (fechaInicio.isEmpty) errores.add('Fecha Inicio inválida (use dd/mm/yyyy)');
    }

    String? fechaFin;
    if (fechaFinRaw.isNotEmpty) {
      final parsed = _parseFechaAIso(fechaFinRaw);
      if (parsed.isEmpty) {
        errores.add('Fecha Fin inválida (use dd/mm/yyyy)');
      } else {
        fechaFin = parsed;
        if (fechaInicio.isNotEmpty &&
            DateTime.parse(fechaFin).isBefore(DateTime.parse(fechaInicio))) {
          errores.add('Fecha Fin debe ser >= Fecha Inicio');
        }
      }
    }

    final esDuplicado = nombre.isNotEmpty && nombresEnDB.contains(nombre.toLowerCase());

    return {
      ...fila,
      'nombre': nombre,
      'subcategoria': normalizado.isNotEmpty ? normalizado : subcategoria,
      'monto': montoNum ?? 0.0,
      'montoRaw': montoRaw,
      'fechaInicio': fechaInicio,
      'fechaInicioRaw': fechaInicioRaw,
      'fechaFin': fechaFin,
      'fechaFinRaw': fechaFinRaw,
      'observaciones': fila['observaciones'] ?? '',
      'unidad': unidad,
      'esDuplicado': esDuplicado,
      'errores': errores,
      'valido': errores.isEmpty,
    };
  }

  // ─── Helpers privados ────────────────────────────────────────────────────

  /// Obtiene el mapa {nombre_subcategoria → id} para subcategorías de ADHE.
  Future<Map<String, int?>> _lookupSubcategoriaIds() async {
    try {
      final db = await AppDatabase.instance();
      final adheRows = await db.query(
        'categoria_movimiento',
        columns: ['id'],
        where: 'codigo = ?',
        whereArgs: ['ADHE'],
      );
      if (adheRows.isEmpty) return {};

      final adheId = adheRows.first['id'] as int;
      final rows = await db.query(
        'subcategorias',
        columns: ['id', 'nombre'],
        where: 'categoria_id = ?',
        whereArgs: [adheId],
      );
      return {
        for (final r in rows) (r['nombre'] as String): r['id'] as int,
      };
    } catch (_) {
      return {};
    }
  }

  /// Convierte un valor de celda Excel a string legible.
  String _cellToString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    // En excel package v2, los CellValue tienen un valor interno:
    return value.toString().trim();
  }

  /// Para celdas de fecha: si es DateTime o string ISO, convierte a dd/mm/yyyy.
  /// Si ya es dd/mm/yyyy, lo devuelve tal cual.
  String _cellToFechaString(dynamic value) {
    if (value == null) return '';

    // Si el paquete devolvió un DateTime
    if (value is DateTime) {
      return '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
    }

    final raw = value.toString().trim();
    if (raw.isEmpty) return '';

    // Si ya parece dd/mm/yyyy → devolverlo directo
    if (raw.contains('/')) return raw;

    // Si parece un DateTime.toString() "2026-03-01 00:00:00.000"
    if (raw.contains('-') && raw.contains(':')) {
      try {
        final dt = DateTime.parse(raw);
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
      } catch (_) {}
    }

    // Si parece YYYY-MM-DD
    final isoMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (isoMatch != null) {
      return '${isoMatch.group(3)}/${isoMatch.group(2)}/${isoMatch.group(1)}';
    }

    // Puede ser número serial de Excel (días desde 1900-01-00)
    final serial = double.tryParse(raw);
    if (serial != null && serial > 40000) {
      final excelEpoch = DateTime(1899, 12, 30);
      final dt = excelEpoch.add(Duration(days: serial.toInt()));
      return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    }

    return raw;
  }

  /// Parsea una fecha en varios formatos y devuelve YYYY-MM-DD.
  /// Devuelve '' si no se puede parsear.
  String _parseFechaAIso(String raw) {
    if (raw.isEmpty) return '';

    // dd/mm/yyyy
    final slashParts = raw.split('/');
    if (slashParts.length == 3) {
      final d = int.tryParse(slashParts[0]);
      final m = int.tryParse(slashParts[1]);
      final y = int.tryParse(slashParts[2]);
      if (d != null && m != null && y != null &&
          d >= 1 && d <= 31 && m >= 1 && m <= 12 && y >= 2000 && y <= 2100) {
        return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
      }
    }

    // Formato ISO YYYY-MM-DD
    final isoMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (isoMatch != null) {
      final y = int.tryParse(isoMatch.group(1)!);
      final m = int.tryParse(isoMatch.group(2)!);
      final d = int.tryParse(isoMatch.group(3)!);
      if (y != null && m != null && d != null &&
          y >= 2000 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return raw;
      }
    }

    // dd-mm-yyyy
    final dashParts = raw.split('-');
    if (dashParts.length == 3 && dashParts[0].length <= 2) {
      final d = int.tryParse(dashParts[0]);
      final m = int.tryParse(dashParts[1]);
      final y = int.tryParse(dashParts[2]);
      if (d != null && m != null && y != null &&
          d >= 1 && d <= 31 && m >= 1 && m <= 12 && y >= 2000 && y <= 2100) {
        return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
      }
    }

    return '';
  }
}
