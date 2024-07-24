import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:freedesktop_desktop_entry/freedesktop_desktop_entry.dart';
import 'package:freedesktop_desktop_entry/src/icon_theme_key.dart';
import 'package:freedesktop_desktop_entry/src/utils.dart';
import 'package:path/path.dart' as path;

import 'entry.dart';

class FreedesktopIconTheme {
  static List<Directory> get _baseDirectories =>
      whereExists(getIconBaseDirectories().map(Directory.new)).toList();

  /// List of themes installed in the system.
  static Future<Set<String>> get installedThemes async {
    final allFolders = (await _baseDirectories
            .map((directory) async => directory
                .list(followLinks: false)
                .where((e) => e is Directory)
                .toList())
            .wait)
        .flattened;
    final themeFolders = allFolders
        .where((entity) => File('${entity.path}/index.theme').existsSync())
        .toList();
    return themeFolders.map((folder) => path.basename(folder.path)).toSet();
  }

  final Map<String, DateTime> _baseDirectoriesLastChangedTimes =
      _getBaseDirectoriesChangedTimes(_baseDirectories);
  _IconTheme _iconTheme;
  Map<String, File> _fallbackIcons = {};
  final Map<IconQuery, File?> _cachedMappings = {};
  DateTime _lastIconLookup = DateTime(0);

  static Future<FreedesktopIconTheme> loadTheme({
    required String theme,
    String fallbackTheme = 'hicolor',
  }) async {
    final themesAvailable = await installedThemes;
    final themeToIndex = themesAvailable.contains(theme)
        ? theme
        : themesAvailable.contains(fallbackTheme)
            ? fallbackTheme
            : 'hicolor';

    final iconTheme = await Isolate.run(() {
      print(themeToIndex);
      return _indexTheme(themeToIndex);
    });

    final fallbackIcons = _indexFallbackIcons(
        await _getBaseDirectoryContents(FreedesktopIconTheme._baseDirectories));

    return FreedesktopIconTheme._new(
      iconTheme,
      fallbackIcons,
    );
  }

  FreedesktopIconTheme._new(
    this._iconTheme,
    this._fallbackIcons,
  );

  refresh() async {
    final iconTheme = await Isolate.run(() {
      return _indexTheme(_iconTheme.name);
    });

    final fallbackIcons = _indexFallbackIcons(
        await _getBaseDirectoryContents(FreedesktopIconTheme._baseDirectories));
    _iconTheme = iconTheme;
    _fallbackIcons = fallbackIcons;
  }

  Future<File?> findIcon(IconQuery query) async {
    if (DateTime.now().difference(_lastIconLookup).inSeconds > 5) {
      var modifiedTimes = _getBaseDirectoriesChangedTimes(
          FreedesktopIconTheme._baseDirectories);

      if (!MapEquality()
          .equals(modifiedTimes, _baseDirectoriesLastChangedTimes)) {
        await refresh();
      }
    }

    _lastIconLookup = DateTime.now();

    if (_cachedMappings.containsKey(query)) {
      return _cachedMappings[query];
    }

    // I don't know if environment variables can be used in absolute icon paths, but let's handle them just in case.
    bool isAbsolutePath =
        expandEnvironmentVariables(query.name).startsWith('/');

    File? icon;
    if (isAbsolutePath) {
      icon = File(query.name);
    } else {
      icon = _findIcon(query);
    }
    _cachedMappings[query] = icon;

    return icon;
  }

  File? _findIcon(IconQuery query) {
    File? file = _findIconHelper(
        _iconTheme, query.name, query.size, query.scale, query.extensions);
    if (file != null) {
      return file;
    }
    return _lookupFallbackIcon(query.name, query.extensions);
  }

  File? _findIconHelper(
    _IconTheme theme,
    String icon,
    int size,
    int scale,
    List<String> extensions,
  ) {
    for (_IconTheme theme in _visitIconThemeHierarchy(theme)) {
      File? file = _lookupIcon(theme, icon, size, scale, extensions);
      if (file != null) {
        return file;
      }
    }
    return null;
  }

  Iterable<_IconTheme> _visitIconThemeHierarchy(_IconTheme theme) sync* {
    Set<_IconTheme> visitedThemes = {};

    Iterable<_IconTheme> visit(_IconTheme theme) sync* {
      yield theme;
      visitedThemes.add(theme);

      for (_IconTheme parent in theme.parents) {
        if (!visitedThemes.contains(parent)) {
          yield* visit(parent);
        }
      }
    }

    yield* visit(theme);
  }

  File? _lookupIcon(
    _IconTheme theme,
    String iconName,
    int size,
    int scale,
    List<String> extensions,
  ) {
    for (String extension in extensions) {
      String filename = "$iconName.$extension";
      List<(String, _IconDirectoryDescription)>? iconDirs =
          theme.icons[filename];
      if (iconDirs == null) {
        continue;
      }
      for (var (String iconDirPath, _IconDirectoryDescription iconDir)
          in iconDirs) {
        if (!_directoryMatchesSize(iconDir, size, scale)) {
          continue;
        }
        return File(path.join(iconDirPath, '$iconName.$extension'));
      }
    }

    int? minimalSizeDistance;
    File? closestFile;

    for (String extension in extensions) {
      String filename = "$iconName.$extension";
      List<(String, _IconDirectoryDescription)>? iconDirs =
          theme.icons[filename];
      if (iconDirs == null) {
        continue;
      }
      for (var (String iconDirPath, _IconDirectoryDescription iconDir)
          in iconDirs) {
        final sizeDistance = _directorySizeDistance(iconDir, size, scale);
        if (minimalSizeDistance != null &&
            sizeDistance >= minimalSizeDistance) {
          continue;
        }
        minimalSizeDistance = sizeDistance;
        closestFile = File(path.join(iconDirPath, '$iconName.$extension'));
      }
    }
    return closestFile;
  }

  bool _directoryMatchesSize(
      _IconDirectoryDescription dir, int iconSize, int iconScale) {
    if (dir.scale != iconScale) {
      return false;
    }
    switch (dir.type) {
      case _IconType.fixed:
        return dir.size == iconSize;
      case _IconType.scaled:
        return dir.minSize <= iconSize && iconSize <= dir.maxSize;
      case _IconType.threshold:
        return dir.size - dir.threshold <= iconSize &&
            iconSize <= dir.size + dir.threshold;
    }
  }

  File? _lookupFallbackIcon(String iconName, List<String> extensions) {
    for (String extension in extensions) {
      String filename = "$iconName.$extension";
      File? icon = _fallbackIcons[filename];
      if (icon != null) {
        return icon;
      }
    }
    return null;
  }
}

Future<_IconTheme> _indexTheme(String themeName) async {
  final theme = await _parseIconTheme(themeName);
  await _indexIconThemeIcons(theme!);
  return theme;
}

Future<void> _indexIconThemeIcons(_IconTheme theme) async {
  final themeFolders = FreedesktopIconTheme._baseDirectories
      .map((dir) => Directory('${dir.path}/${theme.name}'))
      .where((dir) => dir.existsSync());

  for (Directory themeDir in themeFolders) {
    final files = themeDir
        .list(recursive: true)
        .where((entity) => entity is File)
        .map((event) => event as File);
    await files.forEach((File file) async {
      String longIconDirectory = path.dirname(file.path);
      String iconDirectory =
          path.normalize(path.relative(longIconDirectory, from: themeDir.path));

      _IconDirectoryDescription? iconDirectoryDescription =
          theme.iconDirectoryDescriptions[iconDirectory];

      if (iconDirectoryDescription == null) {
        return;
      }

      String iconFileName = path.basename(file.path);
      theme.icons
          .putIfAbsent(iconFileName, () => [])
          .add((path.absolute(longIconDirectory), iconDirectoryDescription));
    });
  }
  // index parents
  await theme.parents.map((parent) => _indexIconThemeIcons(parent)).wait;
}

Map<String, DateTime> _getBaseDirectoriesChangedTimes(
    Iterable<Directory> baseDirectories) {
  return Map.fromEntries(baseDirectories.map((dir) {
    var stat = dir.statSync();
    return MapEntry(dir.absolute.path, stat.changed);
  }));
}

Future<Map<Directory, List<FileSystemEntity>>> _getBaseDirectoryContents(
    Iterable<Directory> baseDirectories) async {
  return Map.fromEntries(await baseDirectories.map((Directory dir) async {
    return MapEntry(dir, await dir.list().toList());
  }).wait);
}

Map<String, File> _indexFallbackIcons(
    Map<Directory, List<FileSystemEntity>> baseDirectoryContents) {
  final Map<String, File> fallbackIcons = {};
  Iterable<File> baseIconDirectoryFiles =
      baseDirectoryContents.values.flattened.whereType<File>();
  for (File file in baseIconDirectoryFiles) {
    fallbackIcons.putIfAbsent(path.basename(file.path), () => file);
  }
  return fallbackIcons;
}

Future<_IconTheme?> _parseIconTheme(String themeName) async {
  final themeFolders = FreedesktopIconTheme._baseDirectories
      .map((dir) => Directory('${dir.path}/$themeName'))
      .where((dir) => dir.existsSync());
  if (themeFolders.isEmpty) {
    return null;
  }
  final consideredThemeFolder = themeFolders
      .firstWhereOrNull((dir) => File('${dir.path}/index.theme').existsSync());

  if (consideredThemeFolder == null) {
    return null;
  }

  final themeDescription =
      await _parseIconThemeDescription(consideredThemeFolder.path);
  return _IconTheme(
    name: themeName,
    description: themeDescription,
    parents: (await themeDescription.parents
            .map((themeName) => _parseIconTheme(themeName))
            .toList()
            .wait)
        .nonNulls
        .toList(),
  );
}

class IconQuery extends Equatable {
  final String name;
  final int size;
  final int scale;
  final List<String> extensions;

  IconQuery({
    required this.name,
    required this.size,
    this.scale = 1,
    required this.extensions,
  });

  @override
  List<Object?> get props => [name, size, scale, extensions];
}

class _IconThemeDescription extends Equatable {
  final String name;
  final List<String> parents;
  final Map<String, _IconDirectoryDescription> iconDirectoryDescriptions;

  _IconThemeDescription({
    required this.name,
    required this.parents,
    required this.iconDirectoryDescriptions,
  });

  @override
  List<Object?> get props => [name];
}

class _IconTheme {
  final String name;
  final List<_IconTheme> parents;
  Map<String, _IconDirectoryDescription> get iconDirectoryDescriptions =>
      description.iconDirectoryDescriptions;
  final _IconThemeDescription description;
  // Map<icon file name, List<(icon dir path, icon dir descriptor)>>
  final Map<String, List<(String, _IconDirectoryDescription)>> icons = {};

  _IconTheme(
      {required this.name, required this.description, required this.parents});
}

enum _IconType {
  fixed('Fixed'),
  scaled('Scaled'),
  threshold('Threshold');

  final String string;

  const _IconType(this.string);
}

class _IconDirectoryDescription extends Equatable {
  final String name;
  final int size;
  final _IconType type;
  final int scale;
  final int minSize;
  final int maxSize;
  final int threshold;

  _IconDirectoryDescription({
    required this.name,
    required this.size,
    _IconType? type,
    int? scale,
    int? minSize,
    int? maxSize,
    int? threshold,
  })  : type = type ?? _IconType.threshold,
        scale = scale ?? 1,
        minSize = minSize ?? size,
        maxSize = maxSize ?? size,
        threshold = threshold ?? 2;

  @override
  List<Object?> get props =>
      [name, size, type, scale, minSize, maxSize, threshold];
}

int _directorySizeDistance(
    _IconDirectoryDescription dir, int iconSize, int iconScale) {
  switch (dir.type) {
    case _IconType.fixed:
      return (dir.size * dir.scale - iconSize * iconScale).abs();
    case _IconType.scaled:
      if (iconSize * iconScale < dir.minSize * dir.scale) {
        return dir.minSize * dir.scale - iconSize * iconScale;
      }
      if (iconSize * iconScale > dir.maxSize * dir.scale) {
        return iconSize * iconScale - dir.maxSize * dir.scale;
      }
      return 0;
    case _IconType.threshold:
      if (iconSize * iconScale < (dir.size - dir.threshold) * dir.scale) {
        return dir.minSize * dir.scale - iconSize * iconScale;
      }
      if (iconSize * iconScale > (dir.size + dir.threshold) * dir.scale) {
        return iconSize * iconScale - dir.maxSize * dir.scale;
      }
      return 0;
  }
}

Future<_IconThemeDescription> _parseIconThemeDescription(
    String themeDirectoryPath) async {
  try {
    final indexFile = File(path.join(themeDirectoryPath, "index.theme"));
    final sections = parseSections(await indexFile.readAsString());
    final entries = sections['Icon Theme']!;

    Map<String, _IconDirectoryDescription> iconDirectoryDescriptions = {};
    List<String> iconDirs =
        entries[IconThemeKey.directories.string]!.value.getStringList(',');

    for (String iconDir in iconDirs) {
      Map<String, Entry>? entries = sections[iconDir];
      if (entries == null) {
        continue;
      }
      try {
        String? type = entries[IconThemeKey.type.string]?.value;

        iconDirectoryDescriptions[iconDir] = _IconDirectoryDescription(
          name: iconDir,
          size: entries[IconThemeKey.size.string]!.value.getInteger()!,
          type: _IconType.values.firstWhereOrNull((e) => e.string == type),
          scale: entries[IconThemeKey.scale.string]?.value.getInteger(),
          minSize: entries[IconThemeKey.minSize.string]?.value.getInteger(),
          maxSize: entries[IconThemeKey.maxSize.string]?.value.getInteger(),
          threshold: entries[IconThemeKey.threshold.string]?.value.getInteger(),
        );
      } catch (_) {
        continue;
      }
    }

    List<String> parents =
        entries[IconThemeKey.inherits.string]?.value.getStringList(',') ?? [];
    String themeName = path.basename(themeDirectoryPath);
    if (themeName != 'hicolor' && !parents.contains('hicolor')) {
      // hicolor must always be in the inheritance tree.
      parents.add('hicolor');
    }

    final iconTheme = _IconThemeDescription(
      name: themeName,
      parents: parents,
      iconDirectoryDescriptions: iconDirectoryDescriptions,
    );

    return iconTheme;
  } catch (_) {
    throw Exception("Invalid icon theme: $themeDirectoryPath");
  }
}
