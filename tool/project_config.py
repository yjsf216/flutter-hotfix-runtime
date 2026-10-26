"""Native build options shared by both platform entrypoints.

Old flat keys remain readable for existing projects and frozen receipts.
Never rewrite an archive or merge two competing representations.
"""

import base64
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

_KEYS = {
    'android': {'flavor': 'androidFlavor'},
    'ios': {'team': 'iosTeam', 'scheme': 'iosScheme',
            'minimumVersion': 'iosMinimumVersion', 'infoPlist': 'iosInfoPlist'},
}


def native_options(config):
    platform = config.get('platform')
    if platform not in _KEYS:
        raise ValueError('Native configuration requires platform android or ios')
    keys = _KEYS[platform]
    legacy = {old for group in _KEYS.values() for old in group.values()}
    if 'native' not in config:
        if (set(config) & legacy) - set(keys.values()):
            raise ValueError('Native options belong to a different platform')
        return {name: config[old] for name, old in keys.items() if old in config}
    if set(config) & legacy:
        raise ValueError('Do not mix native options with legacy flat native keys')
    options = config['native']
    if not isinstance(options, dict) or set(options) - set(keys):
        raise ValueError('Invalid or unknown native options for ' + platform)
    if any(not isinstance(value, str) or (not value.strip() and name != 'flavor') for name, value in options.items()):
        raise ValueError('Native options must be non-empty strings')
    return dict(options)


def _run(args, cwd):
    try:
        return subprocess.run([str(arg) for arg in args], cwd=cwd, check=True,
                              capture_output=True, text=True, timeout=180).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # Build output may contain app-owned credentials. Do not echo it here.
        raise ValueError('Cannot read native build settings; run the project build-tool diagnostic locally') from error


def _choose(values, selected, field):
    values = sorted(set(values))
    if selected is not None:
        if selected not in values:
            raise ValueError('Unknown ' + field + ': ' + selected)
        return selected
    if len(values) != 1:
        raise ValueError('Multiple or missing ' + field + '; specify native.' + field + ': ' + ', '.join(values))
    return values[0]


def _android(config, project, overrides):
    # Ask the evaluated Gradle model, including the App's own dart-define logic.
    script = '''gradle.projectsEvaluated {
  def app = gradle.rootProject.findProject(':app')
  if (app == null) return // Flutter's included Gradle build has no application.
  app.tasks.register('printPatchNativeConfig') {
    doLast {
      def rows = app.android.applicationVariants.findAll { it.buildType.name == 'release' }.collect {
        [flavor: it.flavorName, appId: it.applicationId]
      }
      println('PATCH_NATIVE_CONFIG=' + groovy.json.JsonOutput.toJson(rows))
    }
  }
}
'''
    defines = config.get('dartDefines', {})
    if not isinstance(defines, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in defines.items()):
        raise ValueError('dartDefines must contain string values')
    encoded = ','.join(base64.b64encode((k + '=' + v).encode()).decode() for k, v in defines.items())
    with tempfile.TemporaryDirectory(prefix='patch-native-config-') as folder:
        init = Path(folder) / 'query.gradle'
        init.write_text(script)
        output = _run([project / 'android/gradlew', '--quiet', '--console=plain',
                       '--init-script', init, ':app:printPatchNativeConfig',
                       '-PhotfixRuntime=true', '-Pdart-defines=' + encoded], project / 'android')
    lines = [line.removeprefix('PATCH_NATIVE_CONFIG=') for line in output.splitlines()
             if line.startswith('PATCH_NATIVE_CONFIG=')]
    if len(lines) != 1:
        raise ValueError('Missing or ambiguous Gradle settings response')
    rows = json.loads(lines[0])
    if not isinstance(rows, list) or any(not isinstance(row, dict) or
            not isinstance(row.get('flavor'), str) or not isinstance(row.get('appId'), str) for row in rows):
        raise ValueError('Invalid Gradle variants response')
    names = [row['flavor'] for row in rows]
    selected = overrides.get('flavor')
    channel = defines.get('APP_CHANNEL')
    # Only use an explicit business-channel selection when it exactly names a variant.
    if selected is None and channel in names:
        selected = channel
    flavor = _choose(names, selected, 'flavor')
    candidates = [row for row in rows if row['flavor'] == flavor]
    if len(candidates) != 1:
        raise ValueError('Ambiguous release variant; specify a unique flavor')
    return {'flavor': flavor}, candidates[0]['appId']


def _ios(config, project, overrides):
    directory = project / 'ios'
    listing = json.loads(_run(['xcodebuild', '-list', '-json', '-project', 'Runner.xcodeproj'], directory))
    scheme = _choose(listing['project']['schemes'], overrides.get('scheme'), 'scheme')
    settings_args = []
    for field, key in [('team', 'DEVELOPMENT_TEAM'), ('minimumVersion', 'IPHONEOS_DEPLOYMENT_TARGET')]:
        if field in overrides:
            settings_args.append(key + '=' + overrides[field])
    info = overrides.get('infoPlist')
    dedicated = directory / 'Runner/Info-Hotfix.plist'
    if info is None and dedicated.is_file():
        if plistlib.loads(dedicated.read_bytes()).get('HotfixRuntimeEnabled') is not True:
            raise ValueError('Dedicated Info-Hotfix.plist does not enable the runtime')
        info = 'Runner/Info-Hotfix.plist'
    if info is not None:
        path = Path(info)
        if path.is_absolute() or '..' in path.parts or not (directory / path).is_file():
            raise ValueError('native.infoPlist must stay inside ios/')
        if '$(HOTFIX_RUNNER_INFO_PLIST)' not in (directory / 'Runner.xcodeproj/project.pbxproj').read_text():
            raise ValueError('Custom runtime plist requires Runner-scoped HOTFIX_RUNNER_INFO_PLIST integration')
        settings_args.append('HOTFIX_RUNNER_INFO_PLIST=' + info)
    rows = json.loads(_run(['xcodebuild', '-workspace', 'Runner.xcworkspace', '-scheme', scheme,
                           '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                           '-showBuildSettings', '-json', '-disableAutomaticPackageResolution', '-skipPackageUpdates',
                           *settings_args], directory))
    apps = [row['buildSettings'] for row in rows if row.get('buildSettings', {}).get('WRAPPER_EXTENSION') == 'app']
    if len(apps) != 1:
        raise ValueError('Scheme must resolve exactly one application target')
    settings = apps[0]
    team = settings.get('DEVELOPMENT_TEAM', '')
    if not team or '$(' in team:
        raise ValueError('Configure signing Team in Xcode, or specify native.team')
    if info is not None and settings.get('INFOPLIST_FILE') != info:
        raise ValueError('Xcode did not select the requested runtime plist')
    result = {'team': team, 'scheme': scheme, 'minimumVersion': settings['IPHONEOS_DEPLOYMENT_TARGET']}
    if info is not None:
        result['infoPlist'] = info
    return result, settings['PRODUCT_BUNDLE_IDENTIFIER']


def resolve_config(config, project):
    """Resolve missing inputs only; explicit legacy configurations remain unchanged."""
    options = native_options(config)
    required = {'flavor'} if config['platform'] == 'android' else {'team', 'scheme', 'minimumVersion'}
    if required <= set(options) and config.get('appId'):
        return dict(config)
    native, app_id = (_android if config['platform'] == 'android' else _ios)(config, Path(project), options)
    if not app_id or '$(' in app_id:
        raise ValueError('Native application ID is unresolved')
    if config.get('appId') and config['appId'] != app_id:
        raise ValueError('Configured appId differs from the selected native build')
    result = {k: v for k, v in config.items() if k not in {old for group in _KEYS.values() for old in group.values()}}
    return {**result, 'native': native, 'appId': app_id}


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: project_config.py CONFIG.json (resolve only, no build/sign/publish)')
        source = Path(sys.argv[1]).resolve()
        config = json.loads(source.read_text())
        project = (source.parent / config['project']).resolve()
        print(json.dumps({**resolve_config(config, project), 'project': str(project)}, indent=2))
    except (ValueError, OSError, KeyError) as error:
        sys.exit('ERROR: ' + str(error))
