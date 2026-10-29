import 'dart:io';

import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';

const topology = '''<ZoneGroupState><ZoneGroups>
<ZoneGroup Coordinator="RINCON_BAR" ID="one">
<ZoneGroupMember UUID="RINCON_BAR" ZoneName="TV &amp; Music" Location="http://192.168.1.2:1400/xml/device_description.xml">
<Satellite UUID="RINCON_SUB" ZoneName="Sub" Location="http://192.168.1.5:1400/xml/device_description.xml"/>
</ZoneGroupMember>
<ZoneGroupMember UUID="RINCON_ONE" ZoneName="Kitchen" Location="http://192.168.1.3:1400/xml/device_description.xml"/>
<ZoneGroupMember UUID="RINCON_PAIR" Invisible="1" ZoneName="Pair" Location="http://192.168.1.6:1400/xml/device_description.xml"/>
</ZoneGroup><ZoneGroup Coordinator="RINCON_THREE" ID="two">
<ZoneGroupMember UUID="RINCON_THREE" ZoneName="Bedroom" Location="http://192.168.1.4:1400/xml/device_description.xml"/>
</ZoneGroup></ZoneGroups></ZoneGroupState>''';

String soapResponse(String command, Map<String, String> values) {
  final builder = XmlBuilder();
  builder.element(
    'Envelope',
    nest: () => builder.element(
      'Body',
      nest: () {
        builder.element(
          '${command}Response',
          nest: () {
            for (final entry in values.entries) {
              builder.element(entry.key, nest: entry.value);
            }
          },
        );
      },
    ),
  );
  return builder.buildDocument().toXmlString();
}

void main() {
  final location = Uri.parse(
    'http://192.168.1.2:1400/xml/device_description.xml',
  );
  final room = SonosRoom(
    id: 'RINCON_BAR',
    name: 'TV',
    location: location,
    coordinatorId: 'RINCON_BAR',
  );

  test('description reads room identity and advertised service endpoints', () {
    final device = SonosRoom.description(location, '''<root><device>
      <manufacturer>Sonos, Inc.</manufacturer><UDN>uuid:RINCON_BAR</UDN>
      <friendlyName>Product label</friendlyName><roomName>TV &amp; Music</roomName>
      <serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
      <controlURL>/custom/transport</controlURL></service></serviceList>
      </device></root>''');
    expect(device.id, 'RINCON_BAR');
    expect(device.name, 'TV & Music');
    expect(device.services.values.single, '/custom/transport');
  });

  test('ignores other manufacturers and malformed device identities', () {
    expect(
      () => SonosRoom.description(
        location,
        '<device><manufacturer>Other</manufacturer></device>',
      ),
      throwsA(isA<SonosException>()),
    );
    expect(
      () => SonosRoom.description(
        location,
        '<device><manufacturer>Sonos</manufacturer></device>',
      ),
      throwsA(isA<SonosException>()),
    );
  });

  test(
    'topology retains group coordinators but excludes bonded satellites',
    () {
      final rooms = SonosClient.parseTopology(topology);
      expect(rooms.where((r) => r.visible).map((r) => r.name), [
        'TV & Music',
        'Kitchen',
        'Bedroom',
      ]);
      expect(rooms.where((r) => r.id == 'RINCON_SUB'), isEmpty);
      expect(
        rooms.firstWhere((r) => r.id == 'RINCON_ONE').coordinatorId,
        'RINCON_BAR',
      );
    },
  );

  test('SSDP accepts case-insensitive location only from the advertising speaker', () {
    const response =
        'HTTP/1.1 200 OK\r\nlOcAtIoN: http://192.168.1.2:1400/xml/device_description.xml\r\n';
    expect(sonosLocation(response, InternetAddress('192.168.1.2')), location);
    expect(sonosLocation(response, InternetAddress('192.168.1.9')), isNull);
    expect(
      sonosLocation(
        response.replaceFirst(':1400', ':80'),
        InternetAddress('192.168.1.2'),
      ),
      isNull,
    );
    expect(sonosLocation('garbage', InternetAddress('192.168.1.2')), isNull);
  });

  test(
    'SOAP escaping roundtrips authenticated URI and nested metadata',
    () async {
      const uri = 'https://music.test/stream?id=a&t=token&s=salt';
      final client = SonosClient(
        client: MockClient((request) async {
          expect(request.url.path, '/MediaRenderer/AVTransport/Control');
          expect(request.headers['SOAPACTION'], contains('#SetAVTransportURI'));
          final document = XmlDocument.parse(request.body);
          expect(xmlText(document, 'CurrentURI'), uri);
          expect(xmlText(document, 'CurrentURIMetaData'), '<item>A & B</item>');
          return http.Response(soapResponse('SetAVTransportURI', {}), 200);
        }),
      );
      addTearDown(client.close);
      await client.action(room, SonosClient.av, 'SetAVTransportURI', {
        'InstanceID': 0,
        'CurrentURI': uri,
        'CurrentURIMetaData': '<item>A & B</item>',
      });
    },
  );

  test(
    'SOAP faults are sanitized without echoing stream credentials',
    () async {
      final client = SonosClient(
        client: MockClient(
          (_) async => http.Response(
            '<Envelope><Fault><errorCode>701</errorCode><errorDescription>secret-token</errorDescription></Fault></Envelope>',
            500,
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.action(room, SonosClient.av, 'Play', {'InstanceID': 0}),
        throwsA(
          isA<SonosException>().having(
            (e) => e.toString(),
            'safe error',
            'Sonos: upnp:701',
          ),
        ),
      );
    },
  );

  test(
    'grouping targets the room while playback endpoints stay distinct',
    () async {
      final actions = <String>[];
      final client = SonosClient(
        client: MockClient((request) async {
          final command = request.headers['SOAPACTION']!
              .split('#')
              .last
              .replaceAll('"', '');
          actions.add(command);
          if (command == 'SetAVTransportURI') {
            expect(
              xmlText(XmlDocument.parse(request.body), 'CurrentURI'),
              'x-rincon:RINCON_BAR',
            );
          }
          return http.Response(soapResponse(command, {}), 200);
        }),
      );
      addTearDown(client.close);
      final member = SonosRoom(
        id: 'member',
        name: 'Kitchen',
        location: location,
        coordinatorId: room.id,
      );
      await client.join(member, room);
      await client.ungroup(member);
      expect(actions, [
        'SetAVTransportURI',
        'BecomeCoordinatorOfStandaloneGroup',
      ]);
    },
  );

  test('rejects cross-device control URLs from descriptions', () async {
    final client = SonosClient(
      client: MockClient((_) async => throw StateError('must not send')),
    );
    addTearDown(client.close);
    final unsafe = SonosRoom(
      id: room.id,
      name: room.name,
      location: location,
      coordinatorId: room.id,
      services: {
        'urn:schemas-upnp-org:service:AVTransport:1':
            'http://elsewhere.test/control',
      },
    );
    await expectLater(
      client.action(unsafe, SonosClient.av, 'Play'),
      throwsA(isA<SonosException>()),
    );
  });
}
