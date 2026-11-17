#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate an iOS UTM project linking the two isolated native backends."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess


def identifier(label):
    return hashlib.sha256(('Windows-on-iOS unified UTM:' + label).encode()).hexdigest()[:24].upper()


def prepare(source, backends, output):
    original = source / 'UTM.xcodeproj'
    if not original.is_dir():
        raise ValueError('The pinned UTM source checkout is missing.')
    for name in ('WindowsBackend', 'HengeBackend'):
        if not (backends / f'{name}.framework' / name).is_file():
            raise ValueError(f'Missing {name}.framework; build the backends first.')
    native_sources = sorted((source / 'Platform/Native').rglob('*.swift'))
    if not native_sources:
        raise ValueError('UTM native-engine frontend sources have not been applied.')
    output.mkdir(parents=True, exist_ok=True)
    project = source / 'UTMUnified.xcodeproj'
    # Never rewrite the upstream project. This generated sibling retains its
    # relative source paths and pinned Swift package resolution.
    shutil.copytree(original, project, dirs_exist_ok=True)
    raw = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(original / 'project.pbxproj')])
    data = json.loads(raw)
    objects = data['objects']
    target = next(value for value in objects.values()
                  if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'iOS')
    phases = [objects[key] for key in target['buildPhases']]
    source_phase = next(value for value in phases if value['isa'] == 'PBXSourcesBuildPhase')
    framework_phase = next(value for value in phases if value['isa'] == 'PBXFrameworksBuildPhase')
    group_id = identifier('group')
    objects[group_id] = {'isa': 'PBXGroup', 'children': [], 'name': 'Native ARM Engines', 'sourceTree': '<group>'}
    objects[objects[data['rootObject']]['mainGroup']]['children'].append(group_id)

    for path in native_sources:
        relative = str(path.relative_to(source))
        file_id, build_id = identifier(relative), identifier('source:' + relative)
        objects[file_id] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.swift',
                            'path': relative, 'sourceTree': 'SOURCE_ROOT'}
        objects[build_id] = {'isa': 'PBXBuildFile', 'fileRef': file_id}
        objects[group_id]['children'].append(file_id)
        if build_id not in source_phase['files']:
            source_phase['files'].append(build_id)

    embed_id = identifier('embed phase')
    objects[embed_id] = {'isa': 'PBXCopyFilesBuildPhase', 'buildActionMask': '2147483647',
                         'dstPath': '', 'dstSubfolderSpec': '10', 'files': [],
                         'name': 'Embed Native ARM Engines', 'runOnlyForDeploymentPostprocessing': '0'}
    target['buildPhases'].append(embed_id)
    for name in ('WindowsBackend', 'HengeBackend'):
        file_id, link_id, copy_id = (identifier(name + suffix) for suffix in ('file', 'link', 'copy'))
        objects[file_id] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'wrapper.framework',
                            'path': str(backends / (name + '.framework')), 'sourceTree': '<absolute>'}
        objects[link_id] = {'isa': 'PBXBuildFile', 'fileRef': file_id}
        objects[copy_id] = {'isa': 'PBXBuildFile', 'fileRef': file_id,
                            'settings': {'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']}}
        objects[group_id]['children'].append(file_id)
        framework_phase['files'].append(link_id)
        objects[embed_id]['files'].append(copy_id)

    info = plistlib.loads((source / 'Platform/iOS/Info.plist').read_bytes())
    info['CFBundleDisplayName'] = 'UTM ARM Lab'
    info['UIFileSharingEnabled'] = True
    info['LSSupportsOpeningDocumentsInPlace'] = True
    info['NSMicrophoneUsageDescription'] = 'Allow the Windows guest to use microphone input when enabled.'
    info['NSLocalNetworkUsageDescription'] = 'Virtual machines can access services on your local network.'
    info_path = output / 'UTM-Info.plist'
    info_path.write_bytes(plistlib.dumps(info))
    for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[config_id]['buildSettings']
        search = settings.get('FRAMEWORK_SEARCH_PATHS', ['$(inherited)'])
        if isinstance(search, str):
            search = [search]
        settings['FRAMEWORK_SEARCH_PATHS'] = search + [str(backends)]
        conditions = settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['$(inherited)'])
        if isinstance(conditions, str):
            conditions = conditions.split()
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conditions + ['WITH_NATIVE_ENGINES']
        settings['INFOPLIST_FILE'] = str(info_path)
        settings['PRODUCT_NAME'] = 'UTM'
        settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
        settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
    (project / 'project.pbxproj').write_bytes(plistlib.dumps(data, sort_keys=False))
    for scheme in (project / 'xcshareddata/xcschemes').glob('*.xcscheme'):
        scheme.write_text(scheme.read_text().replace('container:UTM.xcodeproj', 'container:UTMUnified.xcodeproj'))
    print(json.dumps({'project': str(project), 'native_frontend_sources': len(native_sources),
                      'frameworks': ['WindowsBackend', 'HengeBackend']}, indent=2))


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=root / 'work/references/UTM')
    parser.add_argument('--backends', type=Path, default=root / 'build/unified/backends')
    parser.add_argument('--output', type=Path, default=root / 'build/unified')
    args = parser.parse_args()
    prepare(args.source.resolve(), args.backends.resolve(), args.output.resolve())


if __name__ == '__main__':
    main()
