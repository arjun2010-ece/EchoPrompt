import 'dart:io';

/// Where feedback goes; the one place the address is written down.
const supportEmail = 'arjun@echoprompter.app';
const websiteUrl = 'https://echoprompter.app';

/// `mailto:` link for "Email us": the versions help diagnose a problem, and no script text is ever added.
Uri feedbackMailto() => Uri(
  scheme: 'mailto',
  path: supportEmail,
  query: [
    'subject=${Uri.encodeComponent('EchoPrompter feedback')}',
    'body=${Uri.encodeComponent('\n\n\n---\nEchoPrompter on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')}',
  ].join('&'),
);

/// Opens [url] in the default app (mail, browser) with the system opener, so no plugin is needed.
/// False if nothing could open it, for example a Mac with no mail app set up.
Future<bool> openExternal(Uri url) async {
  try {
    final result = Platform.isMacOS
        ? await Process.run('open', [url.toString()])
        : Platform.isWindows
            ? await Process.run('cmd', ['/c', 'start', '', url.toString()])
            : null;
    return result != null && result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
