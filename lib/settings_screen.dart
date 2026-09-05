import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:traccar_client/app_keys.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/qr_code_screen.dart';
import 'package:url_launcher/url_launcher.dart';

import 'geolocation_service.dart';
import 'l10n/app_localizations.dart';
import 'preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool advanced = false;

  String _getAccuracyLabel(String? key) {
    return switch (key) {
      'highest' => AppLocalizations.of(context)!.highestAccuracyLabel,
      'high' => AppLocalizations.of(context)!.highAccuracyLabel,
      'low' => AppLocalizations.of(context)!.lowAccuracyLabel,
      _ => AppLocalizations.of(context)!.mediumAccuracyLabel,
    };
  }

  Future<void> _editSetting(String title, String key, bool isInt, {bool obscure = false}) async {
    final initialValue = isInt
        ? Preferences.instance.getInt(key)?.toString() ?? '0'
        : Preferences.instance.getString(key) ?? '';

    final controller = TextEditingController(text: initialValue);
    final errorMessage = AppLocalizations.of(context)!.invalidValue;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: isInt ? TextInputType.number : TextInputType.text,
          inputFormatters: isInt ? [FilteringTextInputFormatter.digitsOnly] : [],
          obscureText: obscure,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(AppLocalizations.of(context)!.saveButton),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      if (key == Preferences.url) {
        final uri = Uri.tryParse(result);
        if (uri == null || uri.host.isEmpty || !(uri.scheme == 'http' || uri.scheme == 'https')) {
          messengerKey.currentState?.showSnackBar(SnackBar(content: Text(errorMessage)));
          return;
        }
      }
      if (isInt) {
        int? intValue = int.tryParse(result);
        if (intValue != null) {
          if (key == Preferences.heartbeat && intValue > 0 && intValue < 60) {
            intValue = 60; // minimum heartbeat is 60 seconds
          }
          await Preferences.instance.setInt(key, intValue);
        }
      } else {
        await Preferences.instance.setString(key, result);
      }
      await GeolocationService.tracker.setConfig(Preferences.buildConfig());
      setState(() {});
    }
  }

  Future<void> _changePassword() async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: AppLocalizations.of(context)!.passwordLabel),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.saveButton),
          ),
        ],
      ),
    );
    if (result == true) {
      await PasswordService.setPassword(controller.text);
    }
  }

  // Extracts scheme + host + port (no trailing slash); mirrors _origin() in
  // map_screen.dart, duplicated here to avoid coupling this screen to
  // _MapScreenState's private helpers.
  String _origin(String url) {
    final uri = Uri.parse(url.split('#')[0]);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }

  HttpClient _httpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (cert, host, port) => true;

  Future<void> _forgotCredentials() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(l10n.forgotCredentialsDialogTitle),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: l10n.forgotCredentialsFieldHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.saveButton),
          ),
        ],
      ),
    );

    if (input == null) return;
    final value = input.trim();
    if (value.isEmpty) return;

    final ccUrl = Preferences.instance.getString(Preferences.saimosccUrl) ?? '';
    if (!ccUrl.startsWith('https://')) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(l10n.ccUrlRequiredError)));
      return;
    }

    final url = '${_origin(ccUrl)}/cc-com/api/v1/auth/forgotCredentials';

    try {
      final req = await _httpClient().postUrl(Uri.parse(url));
      req.headers.set('content-type', 'application/json');
      req.write(jsonEncode({value.contains('@') ? 'email' : 'username': value}));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode == 200) {
        messengerKey.currentState?.showSnackBar(SnackBar(content: Text(l10n.forgotCredentialsSuccess)));
        return;
      }

      String? msg;
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        if (json['msg'] is String) msg = json['msg'] as String;
      } catch (_) {}

      if (msg != null) {
        messengerKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
      } else if (res.statusCode == 404) {
        // Not a business "account not found" response (those come with a
        // JSON msg from cc-db-communicator) - the endpoint itself is
        // missing, i.e. this backend hasn't been migrated yet.
        messengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(l10n.forgotCredentialsNotAvailableHint),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: l10n.openButton,
            onPressed: () => launchUrl(Uri.parse(ccUrl), mode: LaunchMode.externalApplication),
          ),
        ));
      } else {
        messengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(l10n.ccConnectionError('${res.statusCode} ${res.reasonPhrase}')),
        ));
      }
    } catch (e) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(l10n.ccConnectionError(e.toString()))));
    }
  }

  Widget _buildListTile(String title, String key, bool isInt, {bool obscure = false}) {
    String? value;
    if (isInt) {
      final intValue = Preferences.instance.getInt(key);
      if (intValue != null && (intValue > 0 || key == Preferences.distance)) {
        value = intValue.toString();
      } else {
        value = AppLocalizations.of(context)!.disabledValue;
      }
    } else {
      value = Preferences.instance.getString(key);
    }
    return ListTile(
      title: Text(title),
      subtitle: Text(obscure && (value?.isNotEmpty ?? false) ? '••••••••' : (value ?? '')),
      onTap: () => _editSetting(title, key, isInt, obscure: obscure),
    );
  }

  Widget _buildAccuracyListTile() {
    final accuracyOptions = ['highest', 'high', 'medium', 'low'];
    return ListTile(
      title: Text(AppLocalizations.of(context)!.accuracyLabel),
      subtitle: Text(_getAccuracyLabel(Preferences.instance.getString(Preferences.accuracy))),
      onTap: () async {
        final selectedAccuracy = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(AppLocalizations.of(context)!.accuracyLabel),
            children: accuracyOptions.map((option) => SimpleDialogOption(
              child: Text(_getAccuracyLabel(option)),
              onPressed: () => Navigator.pop(context, option),
            )).toList(),
          ),
        );
        if (selectedAccuracy != null) {
          await Preferences.instance.setString(Preferences.accuracy, selectedAccuracy);
          await GeolocationService.tracker.setConfig(Preferences.buildConfig());
          setState(() {});
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isHighestAccuracy = Preferences.instance.getString(Preferences.accuracy) == 'highest';
    final distance = Preferences.instance.getInt(Preferences.distance);
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settingsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const QrCodeScreen()));
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          _buildListTile(AppLocalizations.of(context)!.idLabel, Preferences.id, false),
          _buildListTile(AppLocalizations.of(context)!.urlLabel, Preferences.url, false),
          _buildAccuracyListTile(),
          _buildListTile(AppLocalizations.of(context)!.distanceLabel, Preferences.distance, true),
          if (isHighestAccuracy || Platform.isAndroid && distance == 0)
            _buildListTile(AppLocalizations.of(context)!.intervalLabel, Preferences.interval, true),
          if (isHighestAccuracy)
            _buildListTile(AppLocalizations.of(context)!.angleLabel, Preferences.angle, true),
          _buildListTile(AppLocalizations.of(context)!.heartbeatLabel, Preferences.heartbeat, true),
          SwitchListTile(
            title: Text(AppLocalizations.of(context)!.advancedLabel),
            value: advanced,
            onChanged: (value) {
              setState(() => advanced = value);
            },
          ),
          if (advanced)
            SwitchListTile(
              title: Text(AppLocalizations.of(context)!.bufferLabel),
              value: Preferences.instance.getBool(Preferences.buffer) ?? true,
              onChanged: (value) async {
                await Preferences.instance.setBool(Preferences.buffer, value);
                await GeolocationService.tracker.setConfig(Preferences.buildConfig());
                setState(() {});
              },
            ),
          if (advanced && Platform.isAndroid)
            SwitchListTile(
              title: Text(AppLocalizations.of(context)!.wakelockLabel),
              value: Preferences.instance.getBool(Preferences.wakelock) ?? false,
              onChanged: (value) async {
                await Preferences.instance.setBool(Preferences.wakelock, value);
                await GeolocationService.tracker.setConfig(Preferences.buildConfig());
                setState(() {});
              },
            ),
          if (advanced)
            SwitchListTile(
              title: Text(AppLocalizations.of(context)!.stopDetectionLabel),
              value: Preferences.instance.getBool(Preferences.stopDetection) ?? true,
              onChanged: (value) async {
                await Preferences.instance.setBool(Preferences.stopDetection, value);
                await GeolocationService.tracker.setConfig(Preferences.buildConfig());
                setState(() {});
              },
            ),
          if (advanced && Platform.isAndroid)
            SwitchListTile(
              title: Text(AppLocalizations.of(context)!.preferPlatformProvidersLabel),
              value: Preferences.instance.getBool(Preferences.preferPlatformProviders) ?? false,
              onChanged: (value) async {
                await Preferences.instance.setBool(Preferences.preferPlatformProviders, value);
                await GeolocationService.tracker.setConfig(Preferences.buildConfig());
                setState(() {});
              },
            ),
          if (advanced)
            ListTile(
              title: Text(AppLocalizations.of(context)!.passwordLabel),
              onTap: _changePassword,
            ),
          const Divider(),
          ListTile(
            title: Text(AppLocalizations.of(context)!.ccSectionTitle),
            dense: true,
          ),
          _buildListTile(AppLocalizations.of(context)!.ccUrlLabel, Preferences.saimosccUrl, false),
          _buildListTile(AppLocalizations.of(context)!.ccUserLabel, Preferences.saimosccUser, false),
          _buildListTile(AppLocalizations.of(context)!.passwordLabel, Preferences.saimosccPassword, false, obscure: true),
          ListTile(
            title: Text(AppLocalizations.of(context)!.forgotCredentialsLabel),
            onTap: _forgotCredentials,
          ),
          const Divider(),
          ListTile(
            title: const Text('YouMapPics'),
            subtitle: const Text('Based on Traccar Client (Apache License 2.0)'),
            trailing: const Icon(Icons.info_outline),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'YouMapPics',
              applicationLegalese: 'Based on Traccar Client\n© Anton Tananaev\nApache License 2.0',
            ),
          ),
        ],
      ),
    );
  }
}
