import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as sio;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'command.dart';
import 'grid.dart';
import 'roles.dart';

final v = "2.0.1.0";

// API docs
/*

[Grid Management]
> place <x> <y> <id> <rot> <heat> - Places cell
> bg <x> <y> <bg> - Sets background
> wrap - Toggles wrap mode
> setinit <code> - Sets initial state on the server

[Logic Management]
> edtype <type> - Is the editor type wanted by the server
> token <token JSON> - Server only, is how server knows of Client's ID and version.

[Hover Management]
> new-hover <uuid> <x> <y> <id> <rot> - Creates new hover
> set-hover <uuid> <x> <y> - Sets the new hover position
> drop-hover <uuid> - Removes the hover

[Cursor Management]
> set-cursor <uuid> <x> <y> - Sets cursor state
> remove-cursor <uuid> - Removes the cursor (client only)

*/

var whitelist = <String>[];
var blacklist = <String>[];

enum ServerType {
  sandbox,
  level,
}

var type = ServerType.sandbox;
var uuidBl = false;

late ArgResults config;

void getConfig(List<String> arguments) {
  final args = ArgParser();
  args.addOption('ip', defaultsTo: 'local');
  args.addOption('port', defaultsTo: '8080');
  args.addOption('versions', defaultsTo: '');
  args.addOption('whitelist', defaultsTo: '');
  args.addOption('blacklist', defaultsTo: '');
  args.addOption('banned_packets', defaultsTo: '');
  args.addOption('wait_time', defaultsTo: '1000');
  args.addFlag('kick-allowed');
  args.addFlag('silent', negatable: false);
  args.addFlag('block_uuid', negatable: false);
  args.addFlag('log', negatable: false);
  args.addFlag('packetpass', negatable: true, defaultsTo: true);

  args.addOption('type', defaultsTo: 'false');
  args.addOption('width', defaultsTo: 'false');
  args.addOption('height', defaultsTo: 'false');

  config = args.parse(arguments);
}

late String ip;
late int port;

// Main function
void main(List<String> arguments) async {
  getConfig(arguments);

  if (config['banned_packets'] != "") {
    bannedPackets.addAll(config['banned_packets'].split(':'));
  }

  final vf = File('versions.txt');
  if (vf.existsSync()) {
    if (!config['silent']) print('Reading allowed versions...');
    versions = vf.readAsLinesSync();
  }

  final whitelistFile = File('whitelist.txt');
  if (whitelistFile.existsSync()) {
    if (!config['silent']) print('Reading allowed IDs...');
    whitelist = whitelistFile.readAsLinesSync();
  }

  final blacklistFile = File('blacklist.txt');
  if (blacklistFile.existsSync()) {
    if (!config['silent']) print('Reading banned IDs...');
    blacklist = blacklistFile.readAsLinesSync();
  }

  final aV = config['versions'].split(':') as List<String>;
  if (aV.isNotEmpty && (config['versions'] != "")) versions.addAll(aV);

  fixVersions();

  final aWL = config['whitelist'].split(':') as List<String>;
  if ((aWL.isNotEmpty) && (config['whitelist'] != "")) versions.addAll(aWL);
  final aBL = config['blacklist'].split(':') as List<String>;
  if (aBL.isNotEmpty) {
    versions.addAll(aBL);
    if (blacklist.contains("@uuid")) {
      uuidBl = true;
    }
  }

  var serverType = config['type'];
  var width = config['width'];
  var height = config['height'];

  if (!config['silent']) {
    print("Welcome to The Puzzle Cell Server Handling System");
  }
  if (!config['silent']) print("Server version: $v");

  if (serverType == "false") {
    print("Please input server type (sandbox [1]/ level [2])");
    stdout.write("Server Type > ");
    serverType = stdin.readLineSync();
  }

  if (serverType != "sandbox" &&
      serverType != "level" &&
      serverType != "1" &&
      serverType != "2") {
    print("Invalid server type");
    return;
  }

  if (serverType == "level" || serverType == "2") type = ServerType.level;

  if (serverType == "sandbox" || serverType == "1") {
    type = ServerType.sandbox;

    if (width == "false") {
      print("Please input grid width");
      stdout.write("Width > ");
      width = stdin.readLineSync()!;
    }

    if (height == "false") {
      print("Please input grid height");
      stdout.write("Height > ");
      height = stdin.readLineSync()!;
    }

    makeGrid(int.parse(width), int.parse(height));
  } else {
    print("Please input level code (P2 or P3 only)");
    stdout.write("Level code > ");
    final code = stdin.readLineSync()!;

    loadStr(code);
  }

  var ip = await parseIP(config['ip']!); // Parse IP

  var port = int.parse(config['port']); // Parse port

  if (arguments.isEmpty) {
    print("[ IP & Port Config ]");
    print(
      "Since there were no arguments passed in, the server has detected that you ran the executable by itself.",
    );
    print(
      "To avoid a bad experience, the server is now prompting you to choose the IP and port",
    );
    print("Options:");
    print(
      "local - This puts it on 127.0.0.1, which is the local host IP. If the ip is local, only your computer can connect to it!",
    );
    print(
      "zero - This puts it on 0.0.0.0, meaning any user connected to your WiFi or Ethernet will be able to join. Also, any person with your IP address can also connect, making this ideal for hosting a server for everyone to join",
    );
    stdout.write("IP > ");
    ip = await parseIP(stdin.readLineSync()!);

    print("Now, on to the port. The port must be a 4-digit number.");
    print(
      "If you don't input a valid number, it will use the default port 8080",
    );
    print(
      "Due to many other types of programs using 8080, since the port has to be different from all other apps using the network, we recommend using something other than the default. You can choose something random, like 5283",
    );

    stdout.write('Port > ');

    port = int.tryParse(stdin.readLineSync()!) ?? 8080;
  }

  final server = await createServer(ip, port);

  if (config['silent']) {
    print('Server should be online');
  } else {
    if (arguments.isNotEmpty) {
      if (ip == "local" || ip == "127.0.0.1") {
        print(
          "You have ran this server on the localhost IP address constant (127.0.0.1 [localhost])",
        );
        print(
          "This means only you can connect to the server, as the localhost IP address only allows the computer it is hosted on to access it",
        );
      } else if (ip == 'zero' || ip == '0.0.0.0') {
        print("You have ran this server on IP 0.0.0.0");
        print(
          "This means only people connected through an ethernet wire can connect to it",
        );
      } else if (ip == 'self') {
        print(
          "WARNING: In 7 seconds it will say at what IP the server is hosted. You have no configured it to be local or zero, meaning it will display your actual IP",
        );
        await Future.delayed(Duration(seconds: 7));
      }
    }
    print(
      'Server should be online, at ws://${server.address.address}:${server.port}/',
    );
  }

  Future.delayed(Duration(milliseconds: 500)).then(
    (v) => setupCommandIso(),
  ); // Commands

  // Timer.periodic(Duration(seconds: 1), (timer) {
  //   stdout.write('> ');
  //   final msg = stdin.readLineSync()!.split(' ');

  //   processCommand(msg.first, msg.sublist(1));
  // });
}

void fixVersions() {
  for (var i = 0; i < versions.length; i++) {
    versions[i] = fixVersion(versions[i]);
  }

  while (versions.contains('')) {
    versions.remove('');
  }
}

String fixVersion(String v) {
  while (v.endsWith(".0")) {
    v = v.substring(
      0,
      v.length - 2,
    ); // No more .0
  }

  return v;
}

var versions = <String>[];

final List<WebSocketChannel> webSockets = [];

String? gridCache;

class CellHover {
  double x;
  double y;
  String id;
  int rot;

  CellHover(this.x, this.y, this.id, this.rot);
}

final Map<String, CellHover> hovers = {};

final List<String> bannedPackets = [
  "edtype",
  "remove-cursor",
];

class ClientCursor {
  double x, y;
  WebSocketChannel author;

  ClientCursor(this.x, this.y, this.author);
}

final Map<String, ClientCursor> cursors = {};

final Map<WebSocketChannel, String> clientIDs = {};
final Set<String> clientIDList = {};

void removeWebsocket(WebSocketChannel ws) {
  if (!webSockets.contains(ws)) return;
  if (!config['silent']) print('User left');
  ws.sink.close();
  webSockets.remove(ws);

  versionMap.remove(ws);
  String? cursorID = clientIDs[ws];
  if (cursorID == null) return;
  clientIDList.remove(cursorID);
  if (!config['silent']) print('User ID: $cursorID');
  cursors.remove(cursorID);
  for (var ws in webSockets) {
    ws.sink.add('remove-cursor $cursorID');
  }
}

Map<WebSocketChannel, String> versionMap = {};

String? latestIP = "";
final ipMap = <WebSocketChannel, String>{};
final bannedIps = <String>{};

void execPacket(String data, WebSocketChannel ws) {
  if (!webSockets.contains(ws)) return;

  if (config['log']) {
    print('Packet from ${clientIDs[ws] ?? "Unknown"} > $data');
  }

  final args = data.split(' ');

  final typeBasedPackets = [];

  if (type == ServerType.level) {
    typeBasedPackets.addAll([
      "bg",
      "wrap",
    ]);
  }

  if (bannedPackets.contains(args.first) ||
      typeBasedPackets.contains(args.first)) {
    print('Kicking user for sending banned packet ${args.first}');
    kickWS(ws);
    return;
  }

  switch (args.first) {
    case "place":
      if (args.length != 6) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      var x = int.parse(args[1]);
      var y = int.parse(args[2]);
      if (wrap) {
        x = (x + grid.length) % grid.length;
        y = (y + grid.first.length) % grid.first.length;
      }

      if (!insideGrid(x, y)) break;

      final old = grid[x][y].copy;
      grid[x][y].id = args[3];
      grid[x][y].rot = int.parse(args[4]);
      grid[x][y].data = parseCellDataStr(args[5]);
      if (old != grid[x][y]) {
        for (var ws in webSockets) {
          ws.sink.add(data);
        }
        gridCache = null;
      }
      break;
    case "bg":
      if (args.length != 4) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      var x = int.parse(args[1]);
      var y = int.parse(args[2]);
      if (wrap) {
        x = (x + grid.length) % grid.length;
        y = (y + grid.first.length) % grid.first.length;
      }

      if (!insideGrid(x, y)) break;

      final old = grid[x][y].bg;
      grid[x][y].bg = args[3];
      if (old != args[3]) {
        for (var ws in webSockets) {
          ws.sink.add(data);
        }
        gridCache = null;
      }
      break;
    case "wrap":
      if (args.length != 1) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      wrap = !wrap;
      for (var ows in webSockets) {
        ows.sink.add(data);
      }
      gridCache = null;
      break;
    case "setinit":
      if (getRole(ws) == UserRole.guest) {
        //ws.sink.add('drop-hover ${args[1]}');
        break;
      }
      if (gridCache != args[1]) {
        loadStr(args[1]);
        for (var ws in webSockets) {
          ws.sink.add(data);
        }
        gridCache = args[1];
      }
      break;
    case "new-hover":
      if (args.length != 6) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      hovers[args[1]] = CellHover(
        double.parse(args[2]),
        double.parse(args[3]),
        args[4],
        int.parse(
          args[5],
        ),
      );
      for (var ws in webSockets) {
        ws.sink.add(data);
      }
      break;
    case "set-hover":
      if (args.length != 4) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      hovers[args[1]]!.x = double.parse(args[2]);
      hovers[args[1]]!.y = double.parse(args[3]);
      for (var ws in webSockets) {
        ws.sink.add(data);
      }
      break;
    case "drop-hover":
      if (args.length != 2) {
        kickWS(ws);
        break;
      }
      if (getRole(ws) == UserRole.guest) {
        break;
      }
      hovers.remove(args[1]);
      for (var ws in webSockets) {
        ws.sink.add(data);
      }
      break;
    case "set-cursor":
      if (args.length != 4) {
        kickWS(ws);
        break;
      }
      if (args[1] != clientIDs[ws]) break;
      if (cursors[args[1]] == null) {
        cursors[args[1]] = ClientCursor(
          double.parse(args[2]),
          double.parse(args[3]),
          ws,
        );
        if (!config['silent']) {
          print('New cursor created. Client ID: ${args[1]}');
        }
      } else {
        cursors[args[1]]!.x = double.parse(args[2]);
        cursors[args[1]]!.y = double.parse(args[3]);
      }
      for (var ws in webSockets) {
        ws.sink.add(data);
      }
      break;
    case "token":
      final tokenJSON = jsonDecode(args.sublist(1).join(" "));
      final v = tokenJSON["version"];
      if (v is! String) {
        kickWS(ws);
        break;
      }
      final id = tokenJSON["clientID"];
      if (id is! String) {
        kickWS(ws);
        break;
      }

      if (id.length > 500 || id.contains("\n")) {
        kickWS(ws);
        break;
      }

      if (clientIDList.contains(id)) {
        if (!config['silent']) {
          print("A user attempted to connect with duplicate ID");
        }
        kickWS(ws);
        break;
      }
      if (whitelist.isNotEmpty) {
        if (whitelist.contains(id)) {
          if (!config['silent']) {
            print("User with whitelisted ID: $id has joined.");
          }
        } else {
          print("User attempted to join with blocked ID");
          kickWS(ws);
          break;
        }
      }

      if (blacklist.isNotEmpty) {
        if (blacklist.contains(id)) {
          if (!config['silent']) {
            print("User attempted to join with a blocked ID");
          }
          kickWS(ws);
          break;
        }
      }

      if (config['block_uuid'] || uuidBl) {
        if (!config['silent']) {
          print('UUID blocking is enabled, validating ID...');
        }
        if (id.split('-').length == 5) {
          if (!config['silent']) print('Blocked ID $id');
          kickWS(ws);
          break;
        }
      }

      roles[id] = defaultRole;

      clientIDList.add(id);

      fixVersions();

      if (versions.contains(fixVersion(v))) {
        versionMap[ws] = fixVersion(v);
        clientIDs[ws] = id;
        if (!config['silent']) {
          print("A new user has joined. ID: $id. Version: $v");
        }
      } else if (versions.isEmpty) {
        versionMap[ws] = fixVersion(v);
        clientIDs[ws] = id;
        if (!config['silent']) {
          print("A new user has joined. ID: $id. Version: $v");
        }
      } else if (versions.isNotEmpty) {
        if (!config['silent']) {
          print("A user has joined with incompatible version");
        }
        kickWS(ws);
      } else {
        versionMap[ws] = fixVersion(v);
        clientIDs[ws] = id;
        if (!config['silent']) {
          print("A new user has joined. ID: $id. Version: $v");
        }
      }
      break;
    default:
      if (config['packetpass']) {
        if (!config['silent']) {
          print(
            'Randomly got invalid packet $data. Sending to other clients.',
          );
        }
        for (var ws in webSockets) {
          ws.sink.add(data);
        }
      }
      break;
  }
}

Future<HttpServer> createServer(String ip, int port) async {
  final ws = webSocketHandler(
    (WebSocketChannel ws) {
      webSockets.add(ws);
      if (latestIP != null) {
        ipMap[ws] = sha256.convert(utf8.encode(latestIP!)).toString();
        latestIP = null;
      }
      ws.stream.listen(
        (data) {
          if (data is String) {
            final d = data.split('\n');
            for (var dt in d) {
              execPacket(dt, ws);
            }
          }
        },
        onDone: () => removeWebsocket(ws),
        onError: (e) => removeWebsocket(ws),
      );

      // Send grid
      gridCache ??= P3.encodeGrid(); // Speeeeeed
      ws.sink.add('grid $gridCache'); // Send to client

      if (type == ServerType.level) {
        ws.sink.add(
          'edtype puzzle',
        ); // Send special editor type

        hovers.forEach(
          (uuid, hover) {
            ws.sink.add(
              'new-hover $uuid ${hover.x} ${hover.y} ${hover.id} ${hover.rot}',
            );
          },
        ); // Send hovering cells

        cursors.forEach(
          (id, cursor) {
            ws.sink.add('set-cursor $id ${cursor.x} ${cursor.y}');
          },
        ); // Send cursors
      }

      fixVersions();
      if (versions.isNotEmpty) {
        Future.delayed(Duration(milliseconds: int.parse(config['wait_time'])))
            .then(
          (v) {
            if (!versions.contains(versionMap[ws])) {
              print("User kicked for no connection token sent");
              kickWS(ws); // Remove for invalid version
            } // Version check
          },
        );
      } // Version checking
    },
  );

  final server = await sio.serve(serverThing(ws), ip, port); // Create server

  return server; // Return server
}

Future<String> parseIP(String ip) async {
  if (ip == 'local' || ip == 'localhost') {
    return '127.0.0.1';
  }

  if (ip == 'zero') {
    return '0.0.0.0';
  }

  if (ip == 'self') {
    return await Ipify.ipv4();
  }

  return ip;
}

void kickWS(WebSocketChannel ws) {
  final kickAllowed = config['kick-allowed'];

  if (kickAllowed) {
    removeWebsocket(ws);
    if (!config['silent']) print('A user has been kicked');
  } else {
    if (!config['silent']) print('A user wasnt kicked');
  }
}

FutureOr<Response> Function(Request rq) serverThing(
    FutureOr<Response> Function(Request) wsHandler) {
  return (Request rq) {
    final ip = rq.headers['X-Forwarded-For'];

    // IP would be null if this was from the host computer
    if (ip != null) {
      final ipHash = sha256.convert(utf8.encode(ip)).toString();

      if (bannedIps.contains(ipHash)) {
        return Future<Response>.value(Response.forbidden("IP has been banned"));
      }
    }

    latestIP = ip;

    if (rq.method != "GET") {
      return Future<Response>.value(Response.ok("Server exists"));
    } else {
      return wsHandler(rq);
    }
  };
}
