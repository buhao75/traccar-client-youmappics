import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:xml/xml.dart';

import 'create_event.dart';
import 'l10n/app_localizations.dart';
import 'main_screen.dart';
import 'preferences.dart';

enum _Status { loading, error, ready }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  _Status _status = _Status.loading;
  String _errorMessage = '';
  late WebViewController _controller;
  String _localStorageJs = '';

  Map<String, dynamic> _tokens = {};
  String _userDetailsXml = '';
  List<String> _registerServiceList = [
    'saimosws/services/manage_tracking_deviceid',
    'saimosws/services/manage_guardtracker_device',
  ];
  int _serviceIndex = 0;
  bool _triedDbCommunicatorRegistration = false;
  List<String> _stayInWords = ['/saimoscc/', '/saimosws/', '/mapstore/', '/ms/', '/cc-com/'];

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    await Permission.locationWhenInUse.request();
    _controller = WebViewController();
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setBackgroundColor(Colors.white);

    // WebViews don't show JS alert()/confirm() dialogs unless the host app
    // renders them itself; without this, MapStore's delete confirmation
    // (window.confirm()) never appears on either platform.
    await _controller.setOnJavaScriptAlertDialog((request) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(request.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(ctx)!.okButton),
            ),
          ],
        ),
      );
    });
    await _controller.setOnJavaScriptConfirmDialog((request) async {
      if (!mounted) return false;
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(request.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(ctx)!.cancelButton),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocalizations.of(ctx)!.okButton),
            ),
          ],
        ),
      );
      return result ?? false;
    });

    final navDelegate = NavigationDelegate(
      onNavigationRequest: (req) {
        if (!req.isMainFrame) return NavigationDecision.navigate;
        if (_stayInWords.any(req.url.contains)) return NavigationDecision.navigate;
        launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
        return NavigationDecision.prevent;
      },
      onPageStarted: (_) {
        if (_localStorageJs.isNotEmpty) {
          _controller.runJavaScript(_localStorageJs);
        }
      },
    );

    if (Platform.isIOS) {
      // WKWebView's default user agent omits the "Mobile/... Safari/..." tokens
      // that real Safari adds, so MapStore's browser-sniffing rejects it as
      // unsupported. Report a real mobile Safari user agent instead.
      await _controller.setUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      );
    }

    if (Platform.isAndroid) {
      final ac = _controller.platform as AndroidWebViewController;
      await ac.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (_) async =>
            GeolocationPermissionsResponse(allow: true, retain: false),
      );
      // Without this, Android's WebView cancels loading on a self-signed
      // certificate (e.g. an internal Control Center server), unlike iOS
      // which already bypasses this via WebViewSSLBypass.swift.
      await (navDelegate.platform as AndroidNavigationDelegate).setOnSSlAuthError((error) {
        error.proceed();
      });
      await ac.setOnShowFileSelector((params) async {
        const ch = MethodChannel('org.traccar.client/file_picker');
        final uris = await ch.invokeListMethod<String>('pickFiles', {
          'mimeTypes': params.acceptTypes.where((t) => t.isNotEmpty).toList(),
          'allowMultiple': params.mode == FileSelectorMode.openMultiple,
        });
        return uris ?? [];
      });
    }

    await _controller.setNavigationDelegate(navDelegate);
    _startFlow();
  }

  // Without an explicit timeout Dart's HttpClient has none and would hang
  // until the OS-level TCP timeout, which can take minutes and would leave
  // the loading spinner stuck with no feedback.
  static const _networkTimeout = Duration(seconds: 15);

  HttpClient _httpClient() => HttpClient()
    ..connectionTimeout = _networkTimeout
    ..badCertificateCallback = (cert, host, port) => true;

  // Extracts scheme + host + port (no trailing slash)
  String _origin(String url) {
    final uri = Uri.parse(url.split('#')[0]);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }

  // Returns ccUrl with trailing slash (preserving path), used for GeoStore endpoints
  String _ccBase(String url) {
    final s = url.split('#')[0];
    return s.endsWith('/') ? s : '$s/';
  }

  Future<void> _startFlow() async {
    final traccarUrl = Preferences.instance.getString(Preferences.url) ?? '';

    // Fetch app service info from tracking server (non-fatal). Uses a
    // platform-neutral filename, separate from the old native Android app's
    // "youmappics-android.json" (which is still served as-is for that
    // app's still-active installs and must not be renamed/removed).
    if (traccarUrl.isNotEmpty) {
      try {
        final infoUrl = '${_origin(traccarUrl)}/appupdates/youmappics.json';
        final req = await _httpClient().getUrl(Uri.parse(infoUrl));
        final res = await req.close();
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          final json = jsonDecode(body) as Map<String, dynamic>;
          if (json['tosregisterdeviceservicelist'] is List) {
            _registerServiceList =
                List<String>.from(json['tosregisterdeviceservicelist'] as List);
          }
          if (json['stayinwebviewurlwords'] is List) {
            _stayInWords =
                List<String>.from(json['stayinwebviewurlwords'] as List);
          }
        }
      } catch (_) {}
    }

    await _authenticateGeoStore();
  }

  Future<void> _authenticateGeoStore() async {
    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    final user = Preferences.instance.getString(Preferences.saimosccUser) ?? '';
    final pass = Preferences.instance.getString(Preferences.saimosccPassword) ?? '';

    final l10n = AppLocalizations.of(context)!;

    if (!ccUrl.startsWith('https://')) {
      _showError(l10n.ccUrlRequiredError);
      return;
    }

    final loginUrl = '${_ccBase(ccUrl)}rest/geostore/session/login';
    final credentials = base64Encode(utf8.encode('$user:$pass'));

    try {
      final req = await _httpClient().postUrl(Uri.parse(loginUrl));
      req.headers
        ..set('Authorization', 'Basic $credentials')
        ..set('content-type', 'application/json')
        ..set('cache-control', 'no-cache');
      final res = await req.close();

      if (res.statusCode == 200) {
        var body = await res.transform(utf8.decoder).join();
        // Older GeoStore wraps the token: {"sessionToken":{...,"token_type":"bearer"}}
        body = body
            .replaceFirst('{"sessionToken":', '')
            .replaceAll(RegExp(r',"token_type":"bearer"\}\}$'), ',"token_type":"bearer"}');
        _tokens = jsonDecode(body) as Map<String, dynamic>;
        _serviceIndex = 0;
        await _registerDevice();
      } else if (res.statusCode == 401) {
        _showError(l10n.ccAuthError401);
      } else {
        _showError(l10n.ccAuthErrorStatus(res.statusCode));
      }
    } on SocketException catch (_) {
      _showError(l10n.ccConnectionTimeoutError(ccUrl));
    } catch (e) {
      _showError(l10n.ccConnectionError(e.toString()));
    }
  }

  // SAIMOS CC's clean cc-db-communicator endpoint, replacing the old Talend
  // job (manage_tracking_deviceid) there. This backend doesn't run
  // cc-db-communicator, so this always 404s and falls through to the legacy
  // GET-based fallback list below (harmless, tried once per app start).
  Future<bool> _registerDeviceViaDbCommunicator() async {
    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    final deviceId = Preferences.instance.getString(Preferences.id) ?? '';
    final username = Preferences.instance.getString(Preferences.saimosccUser) ?? '';
    final token = _tokens['access_token']?.toString() ?? '';
    final url = '${_origin(ccUrl)}/cc-com/api/v1/tracking/registerDevice';

    try {
      final req = await _httpClient().postUrl(Uri.parse(url));
      req.headers.set('content-type', 'application/json');
      req.write(jsonEncode({
        'deviceId': deviceId,
        'username': username,
        'authKey': token,
      }));
      final res = await req.close();
      await res.transform(utf8.decoder).join();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _registerDevice() async {
    final l10n = AppLocalizations.of(context)!;

    if (!_triedDbCommunicatorRegistration) {
      _triedDbCommunicatorRegistration = true;
      if (await _registerDeviceViaDbCommunicator()) {
        await _getUserDetails();
        return;
      }
    }

    if (_serviceIndex >= _registerServiceList.length) {
      // All services exhausted – continue to user details anyway
      _serviceIndex = 0;
      await _getUserDetails();
      return;
    }

    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    final deviceId = Preferences.instance.getString(Preferences.id) ?? '';
    final username = Preferences.instance.getString(Preferences.saimosccUser) ?? '';
    final token = _tokens['access_token']?.toString() ?? '';
    // Fallback list has no leading slash, but the live JSON from
    // appupdates/youmappics.json does (e.g. "/saimosws/services/..."),
    // which would otherwise produce a double slash below.
    final service =
        _registerServiceList[_serviceIndex].replaceFirst(RegExp(r'^/+'), '');

    final serviceUrl = '${_origin(ccUrl)}/$service'
        '?method=runJob'
        '&arg1=--context_param%20deviceid=${Uri.encodeComponent(deviceId)}'
        '&arg3=--context_param%20username=${Uri.encodeComponent(username)}'
        '&arg11=--context_param%20authkey=${Uri.encodeComponent(token)}';

    try {
      final req = await _httpClient().getUrl(Uri.parse(serviceUrl));
      final res = await req.close();
      if (res.statusCode != 200) {
        _serviceIndex++;
        await _registerDevice();
        return;
      }
      // Parse job status – show snackbar on FAILED, but continue regardless
      final body = await res.transform(utf8.decoder).join();
      if (body.contains('jobstatus') && body.contains('FAILED')) {
        _showSnackbar(l10n.ccRegistrationFailed);
      }
      _serviceIndex = 0;
    } catch (_) {
      _serviceIndex++;
      await _registerDevice();
      return;
    }

    await _getUserDetails();
  }

  Future<void> _getUserDetails() async {
    final l10n = AppLocalizations.of(context)!;
    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    final token = _tokens['access_token']?.toString() ?? '';
    final detailsUrl =
        '${_ccBase(ccUrl)}rest/geostore/users/user/details?includeattributes=true';

    try {
      final req = await _httpClient().getUrl(Uri.parse(detailsUrl));
      req.headers.set('Authorization', 'Bearer $token');
      final res = await req.close();
      if (res.statusCode == 200) {
        _userDetailsXml = await res.transform(utf8.decoder).join();
        _buildAndLoadMap();
      } else {
        _showError(l10n.ccUserDetailError(res.statusCode));
      }
    } on SocketException catch (_) {
      _showError(l10n.ccConnectionTimeoutError(ccUrl));
    } catch (e) {
      _showError(l10n.ccGeoStoreError(e.toString()));
    }
  }

  void _buildAndLoadMap() {
    try {
      final userJson = _parseUserXml(_userDetailsXml);
      final security = jsonEncode({
        'user': userJson,
        'errorCause': null,
        'token': _tokens['access_token'],
        'refresh_token': _tokens['refresh_token'],
        'expires': _tokens['expires'],
        'authHeader': '',
        'loginError': null,
        'passwordChanged': false,
        'passwordError': null,
        'changePasswordLoading': false,
      });
      // jsonEncode(security) produces the double-encoded string needed for setItem
      _localStorageJs =
          "window.localStorage.setItem('mapstore2.persist.security', ${jsonEncode(security)});";
    } catch (_) {
      _localStorageJs =
          "window.localStorage.setItem('mapstore2.persist.security', '');";
    }

    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    if (mounted) setState(() => _status = _Status.ready);
    _controller.loadRequest(Uri.parse(ccUrl));
  }

  // Converts GeoStore XML user details to a JSON-compatible Map,
  // matching the structure produced by Android's XmlToJson library.
  Map<String, dynamic> _parseUserXml(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final coercions = <String, dynamic Function(String)>{
      '/id': (v) => int.tryParse(v) ?? v,
      '/enabled': (v) => v == 'true',
      '/groups/group/id': (v) => int.tryParse(v) ?? v,
      '/groups/group/enabled': (v) => v == 'true',
    };
    return _parseElement(doc.rootElement, coercions, '/');
  }

  Map<String, dynamic> _parseElement(
    XmlElement el,
    Map<String, dynamic Function(String)> coercions,
    String path,
  ) {
    final result = <String, dynamic>{};

    for (final attr in el.attributes) {
      final key = attr.name.local;
      final coerce = coercions['$path$key'];
      result[key] = coerce != null ? coerce(attr.value) : attr.value;
    }

    // Group sibling elements by tag to distinguish single vs. repeated
    final childGroups = <String, List<XmlElement>>{};
    for (final child in el.childElements) {
      childGroups.putIfAbsent(child.name.local, () => []).add(child);
    }

    for (final entry in childGroups.entries) {
      final tag = entry.key;
      final children = entry.value;
      final childPath = '$path$tag/';

      dynamic parse(XmlElement child) => child.childElements.isEmpty
          ? child.innerText
          : _parseElement(child, coercions, childPath);

      result[tag] = children.length == 1 ? parse(children[0]) : children.map(parse).toList();
    }

    return result;
  }

  void _showError(String message) {
    if (mounted) {
      setState(() {
        _status = _Status.error;
        _errorMessage = message;
      });
    }
  }

  void _showSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _reload() async {
    setState(() {
      _status = _Status.loading;
      _errorMessage = '';
      _tokens = {};
      _userDetailsXml = '';
      _localStorageJs = '';
      _registerServiceList = [
        'saimosws/services/manage_tracking_deviceid',
        'saimosws/services/manage_guardtracker_device',
      ];
      _serviceIndex = 0;
      _stayInWords = ['/saimoscc/', '/saimosws/', '/mapstore/', '/ms/', '/cc-com/'];
    });
    await _controller.loadRequest(Uri.parse('about:blank'));
    _startFlow();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouMapPics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.warning_amber_rounded),
            tooltip: AppLocalizations.of(context)!.sosAction,
            onPressed: createEventHere,
          ),
          if (_status != _Status.loading)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MainScreen()),
            ),
          ),
        ],
      ),
      body: switch (_status) {
        _Status.loading => const Center(child: CircularProgressIndicator()),
        _Status.error => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(_errorMessage, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _reload,
                    child: Text(AppLocalizations.of(context)!.retryButton),
                  ),
                ],
              ),
            ),
          ),
        _Status.ready => WebViewWidget(controller: _controller),
      },
    );
  }
}
