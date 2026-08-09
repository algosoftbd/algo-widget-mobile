// HTTP transport for the Algo Widget protocol (docs/PROTOCOL.md).
//
// Takes its HTTP client and its attestation provider as inputs rather than
// reaching for them, which is what lets the whole session exchange — the part
// most likely to be got wrong, and the part no device is needed to get wrong —
// be tested without a simulator.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'protocol.dart';

/// Produces a platform attestation for a server-issued challenge.
///
/// Returning null means "I cannot attest" — no Play Services, a simulator, a
/// provider that threw. The client then reports a refusal rather than retrying,
/// because nothing about the next attempt will differ.
typedef AttestationProvider = Future<String?> Function(String challenge);

/// What the app says about itself. Untrusted display data server-side, exactly
/// like a reporter's typed name — the identity half (platform, appId) comes off
/// the verified ticket and is not sent here.
class AppFacts {
  const AppFacts({
    this.appVersion,
    this.buildNumber,
    this.osVersion,
    this.deviceModel,
    this.locale,
  });

  final String? appVersion;
  final String? buildNumber;
  final String? osVersion;

  /// Model NAME ('Pixel 8'). Never a device identifier: nothing here may single
  /// out a handset across reports.
  final String? deviceModel;
  final String? locale;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (appVersion != null) json['appVersion'] = appVersion;
    if (buildNumber != null) json['buildNumber'] = buildNumber;
    if (osVersion != null) json['osVersion'] = osVersion;
    if (deviceModel != null) json['deviceModel'] = deviceModel;
    if (locale != null) json['locale'] = locale;
    return json;
  }
}

class PortalConfig {
  const PortalConfig({
    required this.title,
    required this.recordingEnabled,
    required this.recordingModes,
    required this.recordingMaxSeconds,
    required this.crashCapture,
    required this.maxAttachments,
    this.accentColor,
  });

  factory PortalConfig.fromJson(Map<String, Object?> json) => PortalConfig(
        title: json['title'] as String? ?? 'Report a problem',
        accentColor: json['accentColor'] as String?,
        recordingEnabled: json['recordingEnabled'] == true,
        recordingModes: (json['recordingModes'] as List<Object?>? ?? const [])
            .cast<String>(),
        recordingMaxSeconds:
            (json['recordingMaxSeconds'] as num?)?.toInt() ?? 300,
        // Absent means OFF, never inferred — a client that armed crash capture
        // because a field was missing would be observing an app whose portal
        // never said it could.
        crashCapture: json['crashCapture'] == true,
        maxAttachments:
            (json['maxAttachments'] as num?)?.toInt() ?? kMaxAttachments,
      );

  final String title;
  final String? accentColor;
  final bool recordingEnabled;
  final List<String> recordingModes;
  final int recordingMaxSeconds;
  final bool crashCapture;
  final int maxAttachments;
}

class Ticket {
  const Ticket({required this.token, required this.exp, required this.portal});

  final String token;
  final int exp;
  final PortalConfig portal;
}

/// What a session attempt produced.
///
/// A challenge is NOT a failure — it is step one of the exchange, and an SDK
/// that reports it as an error has misread the protocol (PROTOCOL.md §1).
sealed class SessionResult {
  const SessionResult();
}

class SessionTicket extends SessionResult {
  const SessionTicket(this.ticket);
  final Ticket ticket;
}

class SessionChallenge extends SessionResult {
  const SessionChallenge(this.challenge, this.exp);
  final String challenge;
  final int exp;
}

class SessionRefused extends SessionResult {
  const SessionRefused(this.status, this.reason, {this.retryable = false});
  final int status;
  final String reason;
  final bool retryable;
}

class StagedFile {
  const StagedFile({
    required this.fileId,
    required this.name,
    required this.contentType,
    required this.size,
  });

  factory StagedFile.fromJson(Map<String, Object?> json) => StagedFile(
        fileId: json['fileId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        contentType: json['contentType'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );

  final String fileId;
  final String name;
  final String contentType;
  final int size;

  Map<String, Object?> toJson() => {
        'fileId': fileId,
        'name': name,
        'contentType': contentType,
        'size': size,
      };
}

/// Re-mint this far before a ticket actually expires, so a long upload cannot
/// finish against a ticket that died mid-flight.
const int _ticketSkewMs = 60 * 1000;

class AlgoWidgetClient {
  AlgoWidgetClient({
    required String host,
    required this.portalKey,
    required this.platform,
    required this.appId,
    this.app,
    this.attest,
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : host = host.replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final String host;

  /// The portal's `pk_…` key. Not a secret: it ships inside the app, which is
  /// the entire reason attestation exists.
  final String portalKey;
  final AlgoPlatform platform;

  /// Package name / bundle id. A LOOKUP KEY, never an identity — the server
  /// uses what the attestation reports.
  final String appId;
  final AppFacts? app;
  final AttestationProvider? attest;

  final http.Client _http;
  final DateTime Function() _clock;

  Ticket? _ticket;
  Future<Ticket?>? _pending;

  PortalConfig? get portal => _ticket?.portal;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// One round trip. Exposed so the exchange can be driven step by step in
  /// tests; ordinary callers want [session].
  Future<SessionResult> requestSession(
      {String? challenge, String? attestation}) async {
    final body = <String, Object?>{
      'key': portalKey,
      'client': <String, Object?>{
        'platform': platform.wire,
        'appId': appId,
        if (challenge != null) 'challenge': challenge,
        if (attestation != null) 'attestation': attestation,
        if (app != null) 'app': app!.toJson(),
      },
    };

    http.Response res;
    try {
      res = await _http.post(
        Uri.parse('$host/api/widget/session'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (err) {
      // A network failure IS retryable — unlike every refusal below, next time
      // really might differ.
      return SessionRefused(0, err.toString(), retryable: true);
    }

    final json = _decode(res.body);
    final token = json['token'];
    if (res.statusCode == 200 && token is String) {
      return SessionTicket(Ticket(
        token: token,
        exp: (json['exp'] as num?)?.toInt() ?? _nowMs + 30 * 60 * 1000,
        portal: PortalConfig.fromJson(
          (json['portal'] as Map<String, Object?>?) ?? const {},
        ),
      ));
    }
    // 401 + challenge is STEP ONE, not an error. Reporting it as a failure is
    // the single most likely way to misimplement this protocol.
    final challengeValue = json['challenge'];
    if (res.statusCode == 401 && challengeValue is String) {
      return SessionChallenge(
        challengeValue,
        (json['exp'] as num?)?.toInt() ?? _nowMs + 120 * 1000,
      );
    }
    return SessionRefused(
      res.statusCode,
      json['error'] as String? ?? 'session refused (${res.statusCode})',
      // 429 is the only refusal worth trying again later; the rest are
      // configuration, and retrying a misconfiguration is just noise.
      retryable: res.statusCode == 429,
    );
  }

  /// A valid ticket, minting one if needed. Null when the portal will not have
  /// us — which callers must treat as "hide the report button", never as an
  /// error to show a reporter.
  Future<Ticket?> session() {
    final current = _ticket;
    if (current != null && current.exp - _ticketSkewMs > _nowMs) {
      return Future.value(current);
    }
    // Coalesce: a crash flush and a reporter pressing the button at the same
    // moment must not race two exchanges.
    return _pending ??= _mint().whenComplete(() => _pending = null);
  }

  Future<Ticket?> _mint() async {
    final first = await requestSession();
    if (first is SessionTicket) {
      _ticket = first.ticket;
      return _ticket;
    }
    if (first is SessionRefused) return null;

    final challenge = (first as SessionChallenge).challenge;
    final provider = attest;
    if (provider == null) return null;

    String? token;
    try {
      token = await provider(challenge);
    } catch (_) {
      token = null;
    }
    if (token == null) return null;

    // Exactly ONE retry: a second challenge would be a second chance at the
    // same deterministic outcome.
    final second =
        await requestSession(challenge: challenge, attestation: token);
    if (second is! SessionTicket) return null;
    _ticket = second.ticket;
    return _ticket;
  }

  /// Stage one piece of evidence.
  ///
  /// Refuses over-cap and unknown-extension files HERE rather than uploading
  /// them to be refused: the reporter is on a phone, probably on mobile data,
  /// and finding out after a 60 MB upload is the worst possible time.
  Future<StagedFile?> stage(
      Uint8List bytes, String filename, String contentType) async {
    final kind = kindForFilename(filename);
    if (kind == null) return null;
    final cap = kMaxBytes[kind];
    if (cap == null || bytes.length > cap) return null;

    final ticket = await session();
    if (ticket == null) return null;

    final request = http.MultipartRequest(
        'POST', Uri.parse('$host/api/widget/files'))
      ..headers['x-widget-token'] = ticket.token
      ..files
          .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    try {
      final streamed = await request.send();
      final res = await http.Response.fromStream(streamed);
      if (res.statusCode != 200) return null;
      return StagedFile.fromJson(_decode(res.body));
    } catch (_) {
      return null;
    }
  }

  /// Stage a trace. Its own method because the version stamp and the byte cap
  /// are the two things a caller must not have to remember.
  Future<StagedFile?> stageTrace(Map<String, Object?> trace) async {
    final doc = <String, Object?>{'v': kTraceVersion, ...trace};
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(doc)));
    if (bytes.length > kTraceMaxBytes) return null;
    return stage(bytes, 'trace.json', 'application/json');
  }

  Future<String?> report({
    required String description,
    String reportType = 'bug',
    String? name,
    String? email,
    String? route,
    List<StagedFile> attachments = const [],
  }) async {
    final res = await _authed('/api/widget/report', {
      'description': description,
      'reportType': reportType,
      if (name != null) 'name': name,
      if (email != null) 'email': email,
      if (route != null) 'page': route,
      if (app != null) 'app': app!.toJson(),
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toJson()).toList(),
    });
    if (res == null || res.statusCode != 200) return null;
    return _decode(res.body)['issueId'] as String?;
  }

  Future<bool> crash(Map<String, Object?> report) async {
    final res =
        await _authed('/api/widget/crash', {'v': kCrashVersion, ...report});
    return res != null && res.statusCode == 200;
  }

  Future<http.Response?> _authed(String path, Map<String, Object?> body) async {
    final ticket = await session();
    if (ticket == null) return null;
    try {
      return await _http.post(
        Uri.parse('$host$path'),
        headers: {
          'content-type': 'application/json',
          'x-widget-token': ticket.token
        },
        body: jsonEncode(body),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } catch (_) {
      return <String, Object?>{};
    }
  }

  void close() => _http.close();
}
