import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class SonosException implements Exception {
  const SonosException(this.code);
  final String code;
  @override
  String toString() => 'Sonos: $code';
}

String xmlText(XmlNode node, String name) =>
    node.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == name)
        .map((element) => element.innerText)
        .firstOrNull ??
    '';

class SonosRoom {
  const SonosRoom({
    required this.id,
    required this.name,
    required this.location,
    required this.coordinatorId,
    this.visible = true,
    this.services = const {},
  });
  final String id;
  final String name;
  final Uri location;
  final String coordinatorId;
  final bool visible;
  final Map<String, String> services;

  factory SonosRoom.description(Uri location, String body) {
    final xml = XmlDocument.parse(body);
    if (!xmlText(xml, 'manufacturer').toLowerCase().contains('sonos')) {
      throw const SonosException('notSonos');
    }
    final id = xmlText(xml, 'UDN').replaceFirst('uuid:', '');
    if (id.isEmpty) throw const SonosException('response');
    return SonosRoom(
      id: id,
      name: xmlText(xml, 'roomName').isNotEmpty
          ? xmlText(xml, 'roomName')
          : xmlText(xml, 'friendlyName'),
      location: location,
      coordinatorId: id,
      services: {
        for (final service in xml.findAllElements('service'))
          xmlText(service, 'serviceType'): xmlText(service, 'controlURL'),
      },
    );
  }
}

/// Local UPnP only. Authenticated media URLs are never logged or persisted.
class SonosClient {
  SonosClient({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  static const av = 'AVTransport';
  static const rendering = 'RenderingControl';
  static const topology = 'ZoneGroupTopology';

  Future<SonosRoom> describe(Uri location) async {
    final response = await _http
        .get(location)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw const SonosException('connection');
    try {
      return SonosRoom.description(location, response.body);
    } on FormatException {
      throw const SonosException('response');
    }
  }

  Future<Map<String, String>> action(
    SonosRoom room,
    String service,
    String command, [
    Map<String, Object> args = const {},
  ]) async {
    final type = 'urn:schemas-upnp-org:service:$service:1';
    final path =
        room.services[type] ??
        switch (service) {
          av => '/MediaRenderer/AVTransport/Control',
          rendering => '/MediaRenderer/RenderingControl/Control',
          topology => '/ZoneGroupTopology/Control',
          _ => throw const SonosException('service'),
        };
    final endpoint = room.location.resolve(path);
    if (endpoint.host != room.location.host ||
        endpoint.port != room.location.port) {
      throw const SonosException('response');
    }
    final xml = XmlBuilder();
    xml.element(
      's:Envelope',
      namespaceUris: {'s': 'http://schemas.xmlsoap.org/soap/envelope/'},
      attributes: {
        's:encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
      },
      nest: () {
        xml.element(
          's:Body',
          nest: () {
            xml.element(
              'u:$command',
              namespaceUris: {'u': type},
              nest: () {
                for (final entry in args.entries) {
                  xml.element(entry.key, nest: entry.value.toString());
                }
              },
            );
          },
        );
      },
    );
    try {
      final response = await _http
          .post(
            endpoint,
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$type#$command"',
            },
            body: xml.buildDocument().toXmlString(),
          )
          .timeout(const Duration(seconds: 8));
      final document = XmlDocument.parse(response.body);
      final fault = xmlText(document, 'errorCode');
      if (fault.isNotEmpty) throw SonosException('upnp:$fault');
      if (response.statusCode != 200) throw const SonosException('connection');
      final result = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == '${command}Response')
          .firstOrNull;
      if (result == null) throw const SonosException('response');
      return {
        for (final child in result.childElements)
          child.name.local: child.innerText,
      };
    } on SonosException {
      rethrow;
    } catch (_) {
      // Do not include SOAP envelopes or authenticated stream URLs in errors.
      throw const SonosException('connection');
    }
  }

  Future<List<SonosRoom>> rooms(SonosRoom seed) async {
    final result = await action(seed, topology, 'GetZoneGroupState');
    return parseTopology(result['ZoneGroupState'] ?? '');
  }

  static List<SonosRoom> parseTopology(String value) {
    final document = XmlDocument.parse(value);
    final rooms = <SonosRoom>[];
    for (final group in document.findAllElements('ZoneGroup')) {
      final coordinator = group.getAttribute('Coordinator') ?? '';
      for (final member in group.findElements('ZoneGroupMember')) {
        final location = Uri.tryParse(member.getAttribute('Location') ?? '');
        if (location == null ||
            location.scheme != 'http' ||
            location.host.isEmpty ||
            location.userInfo.isNotEmpty) {
          continue;
        }
        rooms.add(
          SonosRoom(
            id: member.getAttribute('UUID') ?? '',
            name: member.getAttribute('ZoneName') ?? 'Sonos',
            location: location,
            coordinatorId: coordinator,
            visible:
                member.getAttribute('Invisible') != '1' &&
                member.getAttribute('IsZoneBridge') != '1',
          ),
        );
      }
    }
    return rooms;
  }

  Future<void> join(SonosRoom room, SonosRoom coordinator) async {
    if (room.id == coordinator.id) return;
    await action(room, av, 'SetAVTransportURI', {
      'InstanceID': 0,
      'CurrentURI': 'x-rincon:${coordinator.id}',
      'CurrentURIMetaData': '',
    });
  }

  Future<void> ungroup(SonosRoom room) async {
    await action(room, av, 'BecomeCoordinatorOfStandaloneGroup', {
      'InstanceID': 0,
    });
  }

  void close() => _http.close();
}

/// SSDP replies are accepted only from the device that advertised the URL.
Uri? sonosLocation(String response, InternetAddress sender) {
  if (!response.startsWith('HTTP/1.1 200')) return null;
  final headers = <String, String>{};
  for (final line in response.split('\n').skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0) {
      headers[line.substring(0, colon).trim().toLowerCase()] = line
          .substring(colon + 1)
          .trim();
    }
  }
  final location = Uri.tryParse(headers['location'] ?? '');
  if (location == null ||
      location.scheme != 'http' ||
      location.host != sender.address ||
      location.port != 1400 ||
      location.userInfo.isNotEmpty) {
    return null;
  }
  return location;
}

Future<List<Uri>> discoverSonos({
  Duration timeout = const Duration(seconds: 4),
}) async {
  final locations = <String, Uri>{};
  final sockets = <RawDatagramSocket>[];
  final subscriptions = <StreamSubscription<RawSocketEvent>>[];
  const search =
      'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\nMX: 2\r\n'
      'ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n';
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          sockets.add(socket);
          socket.multicastHops = 4;
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              address.rawAddress,
            ),
          );
          subscriptions.add(
            socket.listen((event) {
              if (event != RawSocketEvent.read) return;
              Datagram? packet;
              while ((packet = socket.receive()) != null) {
                final current = packet!;
                final location = sonosLocation(
                  utf8.decode(current.data, allowMalformed: true),
                  current.address,
                );
                if (location != null) locations[location.toString()] = location;
              }
            }, onError: (Object _) {}),
          );
          socket.send(
            utf8.encode(search),
            InternetAddress('239.255.255.250'),
            1900,
          );
        } on SocketException {
          // A disconnected/VPN interface must not prevent Wi-Fi discovery.
        }
      }
    }
    await Future<void>.delayed(timeout);
    return locations.values.toList();
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
  }
}
