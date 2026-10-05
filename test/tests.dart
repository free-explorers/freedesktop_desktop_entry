import 'dart:io';

import 'package:freedesktop_desktop_entry/freedesktop_desktop_entry.dart';
import 'package:test/test.dart';

void main() {
  final file = File("test/desktop_entry_files/desktop-entry-1.desktop");
  final string = file.readAsStringSync();
  final desktopEntry = DesktopEntry.parse(string);

  LocalizedDesktopEntry localizedDesktopEntry = desktopEntry.localize(lang: 'fr', country: 'BE');

  test('localization', () {
    expect(localizedDesktopEntry.entries[DesktopEntryKey.version.string], '1.0');
    expect(localizedDesktopEntry.entries[DesktopEntryKey.name.string], 'Fichier de test 1');
    expect(localizedDesktopEntry.entries[DesktopEntryKey.genericName.string], 'Desktop entry file');
    expect(localizedDesktopEntry.entries[DesktopEntryKey.comment.string], 'Baguette');
    expect(localizedDesktopEntry.entries[DesktopEntryKey.terminal.string]?.getBoolean(), false);
    expect(localizedDesktopEntry.entries[DesktopEntryKey.keywords.string]?.getStringList(), ['Fichier']);
  });

  test('actions', () {
    expect(localizedDesktopEntry.entries[DesktopEntryKey.actions.string]?.getStringList(), ['new-window']);
    expect(localizedDesktopEntry.actions.length, 1);
    expect(desktopEntry.actions['new-window']?[DesktopEntryKey.name.string]?.value, 'Open new window');
    expect(localizedDesktopEntry.actions['new-window']?[DesktopEntryKey.name.string], 'Ouvrir nouvelle fenêtre');
  });

  test('icon name', () async {
    final theme = await FreedesktopIconTheme.loadTheme(theme: 'hicolor');
    File? file = await theme.findIcon(
      IconQuery(
        name: 'input-touchpad',
        size: 32,
        extensions: ['png'],
      ),
    );
    assert(file != null);
    assert(file!.path == '/usr/share/icons/hicolor/32x32/devices/input-touchpad.png');
  });

  test('absolute icon path', () async {
    final theme = await FreedesktopIconTheme.loadTheme(theme: 'hicolor');
    File? file = await theme.findIcon(
      IconQuery(
        name: '/usr/share/icons/hicolor/32x32/devices/input-touchpad.png',
        size: 32, // doesn't matter
        extensions: ['png'], // doesn't matter
      ),
    );
    assert(file != null);
    assert(file!.path == '/usr/share/icons/hicolor/32x32/devices/input-touchpad.png');
  });

  group('parseDesktopFiles', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('freedesktop-desktop-entry');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    void write(Directory directory, String id, String name) {
      File('${directory.path}/$id.desktop').writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=$name\nExec=$id\n',
      );
    }

    test('parses the .desktop files of the given directories', () async {
      final applications = Directory('${root.path}/applications')..createSync();
      write(applications, 'first', 'First');

      final entries = await parseDesktopFiles([applications]);

      expect(entries.keys, ['first']);
      expect(entries['first']?.entries[DesktopEntryKey.name.string]?.value, 'First');
    });

    test('skips directories that do not exist', () async {
      final missing = Directory('${root.path}/missing');
      final applications = Directory('${root.path}/applications')..createSync();
      write(applications, 'first', 'First');

      final entries = await parseDesktopFiles([missing, applications]);

      expect(entries.keys, ['first']);
    });

    test('keeps the first entry when desktop-file ids collide', () async {
      final high = Directory('${root.path}/high/applications')..createSync(recursive: true);
      final low = Directory('${root.path}/low/applications')..createSync(recursive: true);
      write(high, 'shared', 'High');
      write(low, 'shared', 'Low');

      final entries = await parseDesktopFiles([high, low]);

      expect(entries.keys, ['shared']);
      expect(entries['shared']?.entries[DesktopEntryKey.name.string]?.value, 'High');
    });
  });
}
