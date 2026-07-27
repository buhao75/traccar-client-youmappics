import 'package:flutter/material.dart';

import 'app_keys.dart';
import 'geolocation_service.dart';
import 'l10n/app_localizations.dart';

/// Creates a SAIMOS CC event at the device's current location, showing a
/// loading dialog followed by a success/failure dialog. Shared between the
/// home screen quick action and the in-app button so both stay in sync.
Future<void> createEventHere() async {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  final l10n = AppLocalizations.of(context)!;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Text(l10n.sosSending),
        ],
      ),
    ),
  );
  var success = true;
  try {
    await GeolocationService.tracker.requestPosition(alarm: 'sos');
  } catch (_) {
    success = false;
  }
  navigatorKey.currentState?.pop();
  final resultContext = navigatorKey.currentContext;
  if (resultContext == null) return;
  await showDialog<void>(
    context: resultContext, // ignore: use_build_context_synchronously
    builder: (ctx) => AlertDialog(
      content: Text(success ? l10n.sosSent : l10n.sosFailed),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.okButton),
        ),
      ],
    ),
  );
}
