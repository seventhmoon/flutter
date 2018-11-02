// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// This program generates a getTranslation() function that looks up the
// translations contained by the arb files. The returned value is an
// instance of GlobalMaterialLocalizations that corresponds to a single
// locale.
//
// The *.arb files are in packages/flutter_localizations/lib/src/l10n.
//
// The arb (JSON) format files must contain a single map indexed by locale.
// Each map value is itself a map with resource identifier keys and localized
// resource string values.
//
// The arb filenames are expected to have the form "material_(\w+)\.arb", where
// the group following "_" identifies the language code and the country code,
// e.g. "material_en.arb" or "material_en_GB.arb". In most cases both codes are
// just two characters.
//
// This app is typically run by hand when a module's .arb files have been
// updated.
//
// ## Usage
//
// Run this program from the root of the git repository.
//
// The following outputs the generated Dart code to the console as a dry run:
//
// ```
// dart dev/tools/gen_localizations.dart
// ```
//
// If the data looks good, use the `-w` or `--overwrite` option to overwrite the
// packages/flutter_localizations/lib/src/l10n/localizations.dart file:
//
// ```
// dart dev/tools/gen_localizations.dart --overwrite
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:meta/meta.dart';

import 'localizations_utils.dart';
import 'localizations_validator.dart';

const String outputHeader = '''
// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// This file has been automatically generated. Please do not edit it manually.
// To regenerate the file, use:
// @(regenerate)

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../material_localizations.dart';
''';

/// Maps locales to resource key/value pairs.
final Map<String, Map<String, String>> localeToResources = <String, Map<String, String>>{};

/// Maps locales to resource key/attributes pairs.
///
/// See also: <https://github.com/googlei18n/app-resource-bundle/wiki/ApplicationResourceBundleSpecification#resource-attributes>
final Map<String, Map<String, dynamic>> localeToResourceAttributes = <String, Map<String, dynamic>>{};

/// Return `s` as a Dart-parseable raw string in single or double quotes.
///
/// Double quotes are expanded:
///
/// ```
/// foo => r'foo'
/// foo "bar" => r'foo "bar"'
/// foo 'bar' => r'foo ' "'" r'bar' "'"
/// ```
String generateString(String s) {
  if (!s.contains("'"))
    return "r'$s'";

  final StringBuffer output = StringBuffer();
  bool started = false; // Have we started writing a raw string.
  for (int i = 0; i < s.length; i++) {
    if (s[i] == "'") {
      if (started)
        output.write("'");
      output.write(' "\'" ');
      started = false;
    } else if (!started) {
      output.write("r'${s[i]}");
      started = true;
    } else {
      output.write(s[i]);
    }
  }
  if (started)
    output.write("'");
  return output.toString();
}

/// Simple data class to hold parsed locale. Does not promise validity of any data.
class Locale {
  Locale({
    this.languageCode,
    this.scriptCode,
    this.countryCode,
    this.length,
    this.origString
  });

  String languageCode;
  String scriptCode;
  String countryCode;
  int length;          // The number of fields. Ranges from 1-3.
  String origString;   // Original un-parsed locale string.
}

/// Simple parser. Expects the locale string to be in the form of 'language_script_COUNTRY'
/// where the langauge is 2 characters, script is 4 characters with the first uppercase,
/// and country is 2-3 characters and all uppercase.
///
/// 'language_COUNTRY' or 'language_script' are also valid. Missing fields will be null.
Locale parseLocaleString(String locale) {
    final List<String> codes = locale.split('_'); // [language, script, country]
    String scriptCode;
    String countryCode;
    if (codes.length == 2) {
      scriptCode = codes[1].length >= 4 ? codes[1] : null;
      countryCode = codes[1].length < 4 ? codes[1] : null;
    } else if (codes.length == 3) {
      scriptCode = codes[1].length > codes[2].length ? codes[1] : codes[2];
      countryCode = codes[1].length < codes[2].length ? codes[1] : codes[2];
    }
    assert(codes.length == 1 || codes.length == 2 || codes.length == 3);
    assert(codes[0] != null);
    return Locale(
      languageCode: codes[0],
      scriptCode: scriptCode,
      countryCode: countryCode,
      length: codes.length,
      origString: locale,
    );
}

/// This is the core of this script; it generates the code used for translations.
String generateTranslationBundles() {
  final StringBuffer output = StringBuffer();
  final StringBuffer supportedLocales = StringBuffer();

  final Map<String, List<String>> languageToLocales = <String, List<String>>{};
  final Map<String, Set<String>> languageToScriptCodes = <String, Set<String>>{};
  // Used to calculate if there are any corresponding countries for a given language and script.
  final Map<String, Set<String>> languageAndScriptToCountryCodes = <String, Set<String>>{};
  final Set<String> allResourceIdentifiers = Set<String>();
  for (String localeString in localeToResources.keys.toList()..sort()) {
    final Locale locale = parseLocaleString(localeString);
    if (locale.scriptCode != null) {
      languageToScriptCodes[locale.languageCode] ??= Set<String>();
      languageToScriptCodes[locale.languageCode].add(locale.scriptCode);
    }
    if (locale.countryCode != null && locale.scriptCode != null) {
      final String key = locale.languageCode + '_' + locale.scriptCode;
      languageAndScriptToCountryCodes[key] ??= Set<String>();
      languageAndScriptToCountryCodes[key].add(locale.countryCode);
    }
    languageToLocales[locale.languageCode] ??= <String>[];
    languageToLocales[locale.languageCode].add(locale.origString);
    allResourceIdentifiers.addAll(localeToResources[locale.origString].keys);
  }

  output.writeln('''
// The classes defined here encode all of the translations found in the
// `flutter_localizations/lib/src/l10n/*.arb` files.
//
// These classes are constructed by the [getTranslation] method at the bottom of
// this file, and used by the [_MaterialLocalizationsDelegate.load] method defined
// in `flutter_localizations/lib/src/material_localizations.dart`.''');

  // We generate one class per supported language (e.g.
  // `MaterialLocalizationEn`). These implement everything that is needed by
  // GlobalMaterialLocalizations.

  // We also generate one subclass for each locale with a script code (e.g.
  // `MaterialLocalizationZhHant`). Their superclasses are the aforementioned
  // language classes for the same locale but without a script code (e.g.
  // `MaterialLocalizationZh`). This script subclass are defined in a separate
  // .arb file. These classes only override getters that return a different value
  // than their superclass.

  // We also generate one subclass for each locale with a country code (e.g.
  // `MaterialLocalizationEnGb`). Their superclasses are the aforementioned
  // language classes for the same locale but without a country code (e.g.
  // `MaterialLocalizationEn`). These classes only override getters that return
  // a different value than their superclass.

  // If scriptCodes for a language are defined, we expect a scriptCode in locales
  // that contain a countryCode. The superclass becomes the script sublcass
  // (e.g. `MaterialLocalizationZhHant`) and the generated subclass will also
  // contain the script code (e.g. `MaterialLocalizationZhHantTW`). Not defining
  // the scriptCode for the country can result in unexpected resolutions.

  final List<String> allKeys = allResourceIdentifiers.toList()..sort();
  final List<String> languageCodes = languageToLocales.keys.toList()..sort();
  for (String languageName in languageCodes) {
    final String camelCaseLanguage = camelCase(languageName);
    final Map<String, String> languageResources = localeToResources[languageName];
    final String languageClassName = 'MaterialLocalization$camelCaseLanguage';
    final String constructor = generateConstructor(languageClassName, languageName);
    output.writeln('');
    output.writeln('/// The translations for ${describeLocale(languageName)} (`$languageName`).');
    output.writeln('class $languageClassName extends GlobalMaterialLocalizations {');
    output.writeln(constructor);
    for (String key in allKeys) {
      final Map<String, dynamic> attributes = localeToResourceAttributes['en'][key];
      output.writeln(generateGetter(key, languageResources[key], attributes));
    }
    output.writeln('}');
    int countryCodeCount = 0;
    int scriptCodeCount = 0;
    if (languageToScriptCodes.containsKey(languageName)) {
      scriptCodeCount = languageToScriptCodes[languageName].length;
      // Language has scriptCodes, so we need to properly fallback countries to corresponding
      // script default values before language default values.
      for (String scriptCode in languageToScriptCodes[languageName]) {
        final String camelCaseScript = camelCase(languageName + '_' + scriptCode);
        final Map<String, String> scriptResources = localeToResources[languageName + '_' + scriptCode];
        final String scriptClassName = 'MaterialLocalization$camelCaseScript';
        final String constructor = generateConstructor(scriptClassName, languageName + '_' + scriptCode);
        output.writeln('');
        output.writeln('/// The translations for ${describeLocale(languageName)} (`$languageName`).');
        output.writeln('class $scriptClassName extends $languageClassName {');
        output.writeln(constructor);
        for (String key in scriptResources.keys) {
          if (languageResources[key] == scriptResources[key])
            continue;
          final Map<String, dynamic> attributes = localeToResourceAttributes['en'][key];
          output.writeln(generateGetter(key, scriptResources[key], attributes));
        }
        output.writeln('}');

        final List<String> localeCodes = languageToLocales[languageName]..sort();
        for (String localeName in localeCodes) {
          if (localeName == languageName)
            continue;
          if (localeName == languageName + '_' + scriptCode)
            continue;
          if (!localeName.contains(scriptCode))
            continue;
          countryCodeCount += 1;
          final String camelCaseLocaleName = camelCase(localeName);
          final Map<String, String> localeResources = localeToResources[localeName];
          final String localeClassName = 'MaterialLocalization$camelCaseLocaleName';
          final String constructor = generateConstructor(localeClassName, localeName);
          output.writeln('');
          output.writeln('/// The translations for ${describeLocale(localeName)} (`$localeName`).');
          output.writeln('class $localeClassName extends $languageClassName$scriptCode {');
          output.writeln(constructor);
          for (String key in localeResources.keys) {
            // When script fallback contains the key, we compare to it instead of language fallback.
            if (scriptResources.containsKey(key) ? scriptResources[key] == localeResources[key] : languageResources[key] == localeResources[key])
              continue;
            final Map<String, dynamic> attributes = localeToResourceAttributes['en'][key];
            output.writeln(generateGetter(key, localeResources[key], attributes));
          }
         output.writeln('}');
        }
      }
    } else {
      // No scriptCode. Here, we do not compare against script default (because it
      // doesn't exist).
      final List<String> localeCodes = languageToLocales[languageName]..sort();
      for (String localeName in localeCodes) {
        if (localeName == languageName)
          continue;
        countryCodeCount += 1;
        final String camelCaseLocaleName = camelCase(localeName);
        final Map<String, String> localeResources = localeToResources[localeName];
        final String localeClassName = 'MaterialLocalization$camelCaseLocaleName';
        final Locale locale = parseLocaleString(localeName);
        final String scriptCode = locale.scriptCode == null || locale.countryCode == null ? '' : locale.scriptCode;
        final String constructor = generateConstructor(localeClassName, localeName);
        output.writeln('');
        output.writeln('/// The translations for ${describeLocale(localeName)} (`$localeName`).');
        output.writeln('class $localeClassName extends $languageClassName$scriptCode {');
        output.writeln(constructor);
        for (String key in localeResources.keys) {
          if (languageResources[key] == localeResources[key])
            continue;
          final Map<String, dynamic> attributes = localeToResourceAttributes['en'][key];
          output.writeln(generateGetter(key, localeResources[key], attributes));
        }
       output.writeln('}');
      }
    }
    final String scriptCodeMessage = scriptCodeCount == 0 ? '' : ' and $scriptCodeCount script' + (scriptCodeCount == 1 ? '' : 's');
    if (countryCodeCount == 0) {
      if (scriptCodeCount == 0)
        supportedLocales.writeln('///  * `$languageName` - ${describeLocale(languageName)}');
      else
        supportedLocales.writeln('///  * `$languageName` - ${describeLocale(languageName)} (plus $scriptCodeCount script' + (scriptCodeCount == 1 ? '' : 's') + ')');

    } else if (countryCodeCount == 1) {
      supportedLocales.writeln('///  * `$languageName` - ${describeLocale(languageName)} (plus one country variation$scriptCodeMessage)');
    } else {
      supportedLocales.writeln('///  * `$languageName` - ${describeLocale(languageName)} (plus $countryCodeCount country variations$scriptCodeMessage)');
    }
  }

  // Generate the getTranslation function. Given a Locale it returns the
  // corresponding const GlobalMaterialLocalizations.
  output.writeln('''

/// The set of supported languages, as language code strings.
///
/// The [GlobalMaterialLocalizations.delegate] can generate localizations for
/// any [Locale] with a language code from this set, regardless of the region.
/// Some regions have specific support (e.g. `de` covers all forms of German,
/// but there is support for `de-CH` specifically to override some of the
/// translations for Switzerland).
///
/// See also:
///
///  * [getTranslation], whose documentation describes these values.
final Set<String> kSupportedLanguages = HashSet<String>.from(const <String>[
${languageCodes.map<String>((String value) => "  '$value', // ${describeLocale(value)}").toList().join('\n')}
]);

/// Creates a [GlobalMaterialLocalizations] instance for the given `locale`.
///
/// All of the function's arguments except `locale` will be passed to the [new
/// GlobalMaterialLocalizations] constructor. (The `localeName` argument of that
/// constructor is specified by the actual subclass constructor by this
/// function.)
///
/// The following locales are supported by this package:
///
/// {@template flutter.localizations.languages}
$supportedLocales/// {@endtemplate}
///
/// Generally speaking, this method is only intended to be used by
/// [GlobalMaterialLocalizations.delegate].
GlobalMaterialLocalizations getTranslation(
  Locale locale,
  intl.DateFormat fullYearFormat,
  intl.DateFormat mediumDateFormat,
  intl.DateFormat longDateFormat,
  intl.DateFormat yearMonthFormat,
  intl.NumberFormat decimalFormat,
  intl.NumberFormat twoDigitZeroPaddedFormat,
) {
  switch (locale.languageCode) {''');
  const String arguments = 'fullYearFormat: fullYearFormat, mediumDateFormat: mediumDateFormat, longDateFormat: longDateFormat, yearMonthFormat: yearMonthFormat, decimalFormat: decimalFormat, twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat';
  for (String language in languageToLocales.keys) {
    // Only one instance of the language.
    if (languageToLocales[language].length == 1) {
      output.writeln('''
    case '$language':
      return MaterialLocalization${camelCase(languageToLocales[language][0])}($arguments);''');
    } else if (!languageToScriptCodes.containsKey(language)) { // Does not distinguish between scripts. Switch on countryCode directly.
      output.writeln('''
    case '$language': {
      switch (locale.countryCode) {''');
      for (String localeName in languageToLocales[language]) {
        if (localeName == language)
          continue;
        assert(localeName.contains('_'));
        final String countryCode = localeName.substring(localeName.indexOf('_') + 1);
        output.writeln('''
        case '$countryCode':
          return MaterialLocalization${camelCase(localeName)}($arguments);''');
      }
      output.writeln('''
      }
      return MaterialLocalization${camelCase(language)}($arguments);
    }''');
    } else { // Language has scriptCode, add additional switch logic.
      bool hasCountryCode = false;
      output.writeln('''
    case '$language': {
      switch (locale.scriptCode) {''');
      for (String scriptCode in languageToScriptCodes[language]) {
        output.writeln('''
        case '$scriptCode': {''');
        if (languageAndScriptToCountryCodes.containsKey(language + '_' + scriptCode)) {
          output.writeln('''
          switch (locale.countryCode) {''');
          for (String localeName in languageToLocales[language]) {
            final Locale locale = parseLocaleString(localeName);
            if (locale.countryCode == null)
              continue;
            else
              hasCountryCode = true;
            if (localeName == language)
              continue;
            if (locale.scriptCode != scriptCode && locale.scriptCode != null)
              continue;
            final String countryCode = locale.countryCode;
            output.writeln('''
            case '$countryCode':
              return MaterialLocalization${camelCase(localeName)}($arguments);''');
          }
        }
        // Return a fallback locale that matches scriptCode, but not countryCode.
        //
        // Explicitly defined scriptCode fallback:
        if (languageToLocales[language].contains(language + '_' + scriptCode)) {
          if (languageAndScriptToCountryCodes.containsKey(language + '_' + scriptCode)) {
            output.writeln('''
          }''');
          }
          output.writeln('''
          return MaterialLocalization${camelCase(language+'_'+scriptCode)}($arguments);
        }''');
        } else {
          // Not Explicitly defined, fallback to first locale with the same language and
          // script:
          for (String localeName in languageToLocales[language]) {
            final Locale locale = parseLocaleString(localeName);
            if (locale.scriptCode != scriptCode)
              continue;
            if (languageAndScriptToCountryCodes.containsKey(language + '_' + scriptCode)) {
              output.writeln('''
          }''');
            }
            output.writeln('''
          return MaterialLocalization${camelCase(localeName)}($arguments);
        }''');
            break;
          }
        }
      }
      output.writeln('''
      }''');
      if (hasCountryCode) {
      output.writeln('''
      switch (locale.countryCode) {''');
        for (String localeName in languageToLocales[language]) {
          final Locale locale = parseLocaleString(localeName);
          if (localeName == language)
            continue;
          assert(localeName.contains('_'));
          if (locale.countryCode == null)
            continue;
          final String countryCode = locale.countryCode;
          output.writeln('''
        case '$countryCode':
          return MaterialLocalization${camelCase(localeName)}($arguments);''');
        }
        output.writeln('''
      }''');
      }
      output.writeln('''
      return MaterialLocalization${camelCase(language)}($arguments);
    }''');
    }
  }
  output.writeln('''
  }
  assert(false, 'getTranslation() called for unsupported locale "\$locale"');
  return null;
}''');

  return output.toString();
}

/// Returns the appropriate type for getters with the given attributes.
///
/// Typically "String", but some (e.g. "timeOfDayFormat") return enums.
///
/// Used by [generateGetter] below.
String generateType(Map<String, dynamic> attributes) {
  if (attributes != null) {
    switch (attributes['x-flutter-type']) {
      case 'icuShortTimePattern':
        return 'TimeOfDayFormat';
      case 'scriptCategory':
        return 'ScriptCategory';
    }
  }
  return 'String';
}

/// Returns the appropriate name for getters with the given attributes.
///
/// Typically this is the key unmodified, but some have parameters, and
/// the GlobalMaterialLocalizations class does the substitution, and for
/// those we have to therefore provide an alternate name.
///
/// Used by [generateGetter] below.
String generateKey(String key, Map<String, dynamic> attributes) {
  if (attributes != null) {
    if (attributes.containsKey('parameters'))
      return '${key}Raw';
    switch (attributes['x-flutter-type']) {
      case 'icuShortTimePattern':
        return '${key}Raw';
    }
  }
  return key;
}

const Map<String, String> _icuTimeOfDayToEnum = <String, String>{
  'HH:mm': 'TimeOfDayFormat.HH_colon_mm',
  'HH.mm': 'TimeOfDayFormat.HH_dot_mm',
  "HH 'h' mm": 'TimeOfDayFormat.frenchCanadian',
  'HH:mm น.': 'TimeOfDayFormat.HH_colon_mm',
  'H:mm': 'TimeOfDayFormat.H_colon_mm',
  'h:mm a': 'TimeOfDayFormat.h_colon_mm_space_a',
  'a h:mm': 'TimeOfDayFormat.a_space_h_colon_mm',
  'ah:mm': 'TimeOfDayFormat.a_space_h_colon_mm',
};

const Map<String, String> _scriptCategoryToEnum = <String, String>{
  'English-like': 'ScriptCategory.englishLike',
  'dense': 'ScriptCategory.dense',
  'tall': 'ScriptCategory.tall',
};

/// Returns the literal that describes the value returned by getters
/// with the given attributes.
///
/// This handles cases like the value being a literal `null`, an enum, and so
/// on. The default is to treat the value as a string and escape it and quote
/// it.
///
/// Used by [generateGetter] below.
String generateValue(String value, Map<String, dynamic> attributes) {
  if (value == null)
    return null;
  if (attributes != null) {
    switch (attributes['x-flutter-type']) {
      case 'icuShortTimePattern':
        if (!_icuTimeOfDayToEnum.containsKey(value)) {
          throw Exception(
            '"$value" is not one of the ICU short time patterns supported '
            'by the material library. Here is the list of supported '
            'patterns:\n  ' + _icuTimeOfDayToEnum.keys.join('\n  ')
          );
        }
        return _icuTimeOfDayToEnum[value];
      case 'scriptCategory':
        if (!_scriptCategoryToEnum.containsKey(value)) {
          throw Exception(
            '"$value" is not one of the scriptCategory values supported '
            'by the material library. Here is the list of supported '
            'values:\n  ' + _scriptCategoryToEnum.keys.join('\n  ')
          );
        }
        return _scriptCategoryToEnum[value];
    }
  }
  return generateString(value);
}

/// Combines [generateType], [generateKey], and [generateValue] to return
/// the source of getters for the GlobalMaterialLocalizations subclass.
String generateGetter(String key, String value, Map<String, dynamic> attributes) {
  final String type = generateType(attributes);
  key = generateKey(key, attributes);
  value = generateValue(value, attributes);
      return '''

  @override
  $type get $key => $value;''';
}

/// Returns the source of the constructor for a GlobalMaterialLocalizations
/// subclass.
String generateConstructor(String className, String localeName) {
  return '''
  /// Create an instance of the translation bundle for ${describeLocale(localeName)}.
  ///
  /// For details on the meaning of the arguments, see [GlobalMaterialLocalizations].
  const $className({
    String localeName = '$localeName',
    @required intl.DateFormat fullYearFormat,
    @required intl.DateFormat mediumDateFormat,
    @required intl.DateFormat longDateFormat,
    @required intl.DateFormat yearMonthFormat,
    @required intl.NumberFormat decimalFormat,
    @required intl.NumberFormat twoDigitZeroPaddedFormat,
  }) : super(
    localeName: localeName,
    fullYearFormat: fullYearFormat,
    mediumDateFormat: mediumDateFormat,
    longDateFormat: longDateFormat,
    yearMonthFormat: yearMonthFormat,
    decimalFormat: decimalFormat,
    twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
  );''';
}

/// Parse the data for a locale from a file, and store it in the [attributes]
/// and [resources] keys.
void processBundle(File file, { @required String locale }) {
  assert(locale != null);
  localeToResources[locale] ??= <String, String>{};
  localeToResourceAttributes[locale] ??= <String, dynamic>{};
  final Map<String, String> resources = localeToResources[locale];
  final Map<String, dynamic> attributes = localeToResourceAttributes[locale];
  final Map<String, dynamic> bundle = json.decode(file.readAsStringSync());
  for (String key in bundle.keys) {
    // The ARB file resource "attributes" for foo are called @foo.
    if (key.startsWith('@'))
      attributes[key.substring(1)] = bundle[key];
    else
      resources[key] = bundle[key];
  }
}

Future<void> main(List<String> rawArgs) async {
  checkCwdIsRepoRoot('gen_localizations');
  final GeneratorOptions options = parseArgs(rawArgs);

  // filenames are assumed to end in "prefix_lc.arb" or "prefix_lc_cc.arb", where prefix
  // is the 2nd command line argument, lc is a language code and cc is the country
  // code. In most cases both codes are just two characters.

  final Directory directory = Directory(path.join('packages', 'flutter_localizations', 'lib', 'src', 'l10n'));
  final RegExp filenameRE = RegExp(r'material_(\w+)\.arb$');

  try {
    validateEnglishLocalizations(File(path.join(directory.path, 'material_en.arb')));
  } on ValidationError catch (exception) {
    exitWithError('$exception');
  }

  await precacheLanguageAndRegionTags();

  for (FileSystemEntity entity in directory.listSync()) {
    final String entityPath = entity.path;
    if (FileSystemEntity.isFileSync(entityPath) && filenameRE.hasMatch(entityPath)) {
      processBundle(File(entityPath), locale: filenameRE.firstMatch(entityPath)[1]);
    }
  }

  try {
    validateLocalizations(localeToResources, localeToResourceAttributes);
  } on ValidationError catch (exception) {
    exitWithError('$exception');
  }

  final StringBuffer buffer = StringBuffer();
  buffer.writeln(outputHeader.replaceFirst('@(regenerate)', 'dart dev/tools/gen_localizations.dart --overwrite'));
  buffer.write(generateTranslationBundles());

  if (options.writeToFile) {
    final File localizationsFile = File(path.join(directory.path, 'localizations.dart'));
    localizationsFile.writeAsStringSync(buffer.toString());
  } else {
    stdout.write(buffer.toString());
  }
}
