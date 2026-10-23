import 'dart:io';

bool get isMobile => Platform.isIOS || Platform.isAndroid;
bool get isDesktop => Platform.isMacOS || Platform.isWindows;
bool get isMacOS => Platform.isMacOS;
bool get isAndroid => Platform.isAndroid;
