import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PosApp());
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sistema POS SQLite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      home: const PosHomeScreen(),
    );
  }
}

class PosHomeScreen extends StatefulWidget {
  const PosHomeScreen({super.key});

  @override
  State<PosHomeScreen> createState() => _PosHomeScreenState();
}

class _PosHomeScreenState extends State<PosHomeScreen> {
  late final WebViewController _controller;
  Database? _db;

  @override
  void initState() {
    super.initState();
    _initDatabase().then((_) {
      _initWebView();
    });
  }

  Future<void> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pos_database.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // Tabla Tasa
        await db.execute('CREATE TABLE Tasa (id INTEGER PRIMARY KEY, valor REAL)');
        await db.execute('INSERT INTO Tasa (id, valor) VALUES (1, 36.5)');

        // Tabla Clientes
        await db.execute('''
          CREATE TABLE Clientes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cedula TEXT UNIQUE,
            nombre TEXT,
            direccion TEXT,
            telefono TEXT
          )
        ''');

        // Tabla Inventario
        await db.execute('''
          CREATE TABLE Inventario (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nombre TEXT,
            precioDol REAL,
            precioBs REAL,
            existencia REAL
          )
        ''');

        // Tabla Facturas
        await db.execute('''
          CREATE TABLE Facturas (
            numFactura TEXT PRIMARY KEY,
            fecha TEXT,
            cliente TEXT,
            cedula TEXT,
            items TEXT,
            totalDol REAL,
            totalBs REAL,
            estatus TEXT,
            abonos REAL,
            saldo REAL
          )
        ''');

        // Seed initial Excel Data if needed
        await db.execute("INSERT OR IGNORE INTO Clientes (id, cedula, nombre, direccion, telefono) VALUES (1, '12345678', 'Cliente Ejemplo', 'Ciudad', '04140000000')");
        await db.execute("INSERT OR IGNORE INTO Inventario (id, nombre, precioDol, precioBs, existencia) VALUES (1, 'Producto Demo', 10.0, 365.0, 50.0)");
      },
    );
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handleBridgeCall(message.message);
        },
      )
      ..loadFlutterAsset('assets/index.html');
  }

  Future<void> _handleBridgeCall(String jsonString) async {
    final req = jsonDecode(jsonString);
    final id = req['id'];
    final action = req['action'];
    final data = req['data'] ?? {};

    dynamic result;
    String? error;

    try {
      switch (action) {
        case 'obtenerTasa':
          final res = await _db!.query('Tasa', where: 'id = 1');
          result = res.isNotEmpty ? (res.first['valor'] as num).toDouble() : 1.0;
          break;

        case 'actualizarTasa':
          final nuevaTasa = double.tryParse(data['nuevaTasa'].toString()) ?? 1.0;
          await _db!.update('Tasa', {'valor': nuevaTasa}, where: 'id = 1');
          
          final invList = await _db!.query('Inventario');
          for (var item in invList) {
            final pDol = (item['precioDol'] as num).toDouble();
            await _db!.update('Inventario', {'precioBs': pDol * nuevaTasa}, where: 'id = ?', whereArgs: [item['id']]);
          }
          result = nuevaTasa;
          break;

        case 'obtenerClientes':
          final res = await _db!.query('Clientes');
          result = res.map((r) => {
            'id': r['id'],
            'cedula': r['cedula'].toString(),
            'nombre': r['nombre'],
            'direccion': r['direccion'],
            'telefono': r['telefono'].toString(),
          }).toList();
          break;

        case 'guardarCliente':
          final cli = data['cliente'];
          final existing = await _db!.query('Clientes', where: 'cedula = ?', whereArgs: [cli['cedula'].toString()]);
          if (existing.isNotEmpty) {
            await _db!.update('Clientes', {
              'nombre': cli['nombre'],
              'direccion': cli['direccion'],
              'telefono': cli['telefono'].toString(),
            }, where: 'cedula = ?', whereArgs: [cli['cedula'].toString()]);
          } else {
            await _db!.insert('Clientes', {
              'cedula': cli['cedula'].toString(),
              'nombre': cli['nombre'],
              'direccion': cli['direccion'],
              'telefono': cli['telefono'].toString(),
            });
          }
          final res = await _db!.query('Clientes');
          result = res.map((r) => {
            'id': r['id'],
            'cedula': r['cedula'].toString(),
            'nombre': r['nombre'],
            'direccion': r['direccion'],
            'telefono': r['telefono'].toString(),
          }).toList();
          break;

        case 'obtenerInventario':
          final res = await _db!.query('Inventario');
          result = res.map((r) => {
            'id': r['id'],
            'nombre': r['nombre'],
            'precioDol': (r['precioDol'] as num).toDouble(),
            'precioBs': (r['precioBs'] as num).toDouble(),
            'existencia': (r['existencia'] as num).toDouble(),
          }).toList();
          break;

        case 'guardarProducto':
          final prod = data['prod'];
          final tasaActual = (data['tasaActual'] as num).toDouble();
          var pDol = double.tryParse(prod['precioDol'].toString()) ?? 0.0;
          var pBs = double.tryParse(prod['precioBs'].toString()) ?? 0.0;

          if (prod['baseCalculo'] == 'DOL') {
            pBs = pDol * tasaActual;
          } else if (prod['baseCalculo'] == 'BS') {
            pDol = tasaActual > 0 ? pBs / tasaActual : 0.0;
          }

          if (prod['id'] != null && prod['id'].toString().isNotEmpty) {
            final pId = int.parse(prod['id'].toString());
            final curr = await _db!.query('Inventario', where: 'id = ?', whereArgs: [pId]);
            var nExistencia = double.tryParse(prod['existencia'].toString()) ?? 0.0;
            if (prod['esEntradaMercancia'] == true && curr.isNotEmpty) {
              nExistencia += (curr.first['existencia'] as num).toDouble();
            }
            await _db!.update('Inventario', {
              'nombre': prod['nombre'],
              'precioDol': pDol,
              'precioBs': pBs,
              'existencia': nExistencia,
            }, where: 'id = ?', whereArgs: [pId]);
          } else {
            await _db!.insert('Inventario', {
              'nombre': prod['nombre'],
              'precioDol': pDol,
              'precioBs': pBs,
              'existencia': double.tryParse(prod['existencia'].toString()) ?? 0.0,
            });
          }

          final res = await _db!.query('Inventario');
          result = res.map((r) => {
            'id': r['id'],
            'nombre': r['nombre'],
            'precioDol': (r['precioDol'] as num).toDouble(),
            'precioBs': (r['precioBs'] as num).toDouble(),
            'existencia': (r['existencia'] as num).toDouble(),
          }).toList();
          break;

        case 'procesarFactura':
          final fac = data;
          final items = fac['items'] as List;

          for (var item in items) {
            final pId = item['id'];
            final cant = (item['cantidad'] as num).toDouble();
            final curr = await _db!.query('Inventario', where: 'id = ?', whereArgs: [pId]);
            if (curr.isNotEmpty) {
              final stockActual = (curr.first['existencia'] as num).toDouble();
              if (stockActual < cant) {
                throw Exception("Stock insuficiente para \${item['nombre']}");
              }
              await _db!.update('Inventario', {'existencia': stockActual - cant}, where: 'id = ?', whereArgs: [pId]);
            }
          }

          final numFactura = 'FAC-\${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
          final now = DateTime.now();
          final fecha = '\${now.day.toString().padLeft(2, '0')}/\${now.month.toString().padLeft(2, '0')}/\${now.year}';
          final estatus = fac['estatus'] ?? 'PAGADA';
          final totalDol = (fac['totalDol'] as num).toDouble();
          final totalBs = (fac['totalBs'] as num).toDouble();
          final abonos = estatus == 'PAGADA' ? totalDol : 0.0;
          final saldo = totalDol - abonos;

          await _db!.insert('Facturas', {
            'numFactura': numFactura,
            'fecha': fecha,
            'cliente': fac['cliente'],
            'cedula': fac['cedula'].toString(),
            'items': jsonEncode(items),
            'totalDol': totalDol,
            'totalBs': totalBs,
            'estatus': estatus,
            'abonos': abonos,
            'saldo': saldo,
          });

          result = {'exito': true, 'numFactura': numFactura};
          break;

        case 'obtenerFacturas':
          final res = await _db!.query('Facturas', orderBy: 'rowid DESC');
          result = res.map((r) => {
            'numFactura': r['numFactura'].toString(),
            'fecha': r['fecha'],
            'cliente': r['cliente'],
            'cedula': r['cedula'].toString(),
            'items': r['items'],
            'totalDol': (r['totalDol'] as num).toDouble(),
            'totalBs': (r['totalBs'] as num).toDouble(),
            'estatus': r['estatus'],
            'abonos': (r['abonos'] as num).toDouble(),
            'saldo': (r['saldo'] as num).toDouble(),
          }).toList();
          break;

        case 'eliminarFactura':
          final nFac = data['numFactura'].toString();
          final fac = await _db!.query('Facturas', where: 'numFactura = ?', whereArgs: [nFac]);
          if (fac.isNotEmpty) {
            final items = jsonDecode(fac.first['items'] as String) as List;
            for (var item in items) {
              final pId = item['id'];
              final cant = (item['cantidad'] as num).toDouble();
              final inv = await _db!.query('Inventario', where: 'id = ?', whereArgs: [pId]);
              if (inv.isNotEmpty) {
                final currStock = (inv.first['existencia'] as num).toDouble();
                await _db!.update('Inventario', {'existencia': currStock + cant}, where: 'id = ?', whereArgs: [pId]);
              }
            }
            await _db!.delete('Facturas', where: 'numFactura = ?', whereArgs: [nFac]);
          }
          result = {'exito': true};
          break;

        case 'registrarAbono':
          final nFac = data['numFactura'].toString();
          final monto = (data['montoAbono'] as num).toDouble();
          final fac = await _db!.query('Facturas', where: 'numFactura = ?', whereArgs: [nFac]);
          if (fac.isNotEmpty) {
            final totalDol = (fac.first['totalDol'] as num).toDouble();
            final abonoAnterior = (fac.first['abonos'] as num).toDouble();
            final nuevoAbono = abonoAnterior + monto;
            var nuevoSaldo = totalDol - nuevoAbono;
            if (nuevoSaldo < 0.01) nuevoSaldo = 0.0;
            final nuevoEstatus = nuevoSaldo <= 0 ? 'PAGADA' : 'PENDIENTE';

            await _db!.update('Facturas', {
              'estatus': nuevoEstatus,
              'abonos': nuevoAbono,
              'saldo': nuevoSaldo,
            }, where: 'numFactura = ?', whereArgs: [nFac]);

            result = {'exito': true, 'saldoActual': nuevoSaldo};
          } else {
            throw Exception("Factura no encontrada");
          }
          break;

        default:
          throw UnimplementedError('Acción $action no soportada');
      }
    } catch (e) {
      error = e.toString();
    }

    final resp = jsonEncode({'result': result, 'error': error});
    _controller.runJavaScript('window.onNativeResponse($id, ${jsonEncode(resp)})');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
