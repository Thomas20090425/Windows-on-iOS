#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Append explicit commands to the research Henge guest controller over USB.

Requires the pinned Mac JIT virtualenv. This controls a virtual Mac inside the
specified development app; it never restores the physical iPad. No connection
is opened when this module is imported. Command payloads are never printed.
"""
import argparse
import asyncio
from pathlib import Path
import re

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


async def append(device, bundle, payload):
    async with await create_using_usbmux(serial=device, autopair=False) as lockdown:
        async with await HouseArrestService.create(lockdown, bundle) as container:
            # Append rather than truncate/rewrite: the running controller keeps
            # a line cursor. Partial final lines are ignored until completed.
            handle = await container.fopen('/Documents/henge-autopilot.txt', 'a')
            try:
                await container.fwrite(handle, payload)
            finally:
                await container.fclose(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', default='com.thomas20090425.henge')
    parser.add_argument('--command', action='append', default=[])
    parser.add_argument('--commands-file', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9-]+', args.device) or not re.fullmatch(r'[A-Za-z0-9.-]+', args.bundle_id):
        parser.error('Supply a valid explicit device and app identifier.')
    lines = list(args.command)
    if args.commands_file:
        lines.extend(args.commands_file.read_text(encoding='utf-8').splitlines())
    if not lines or any('\n' in line or '\r' in line for line in lines):
        parser.error('Supply one or more complete command lines.')
    payload = ('\n'.join(lines) + '\n').encode('utf-8')
    if len(payload) > 65536:
        parser.error('A command batch must be at most 64 KiB.')
    asyncio.run(append(args.device, args.bundle_id, payload))
    print(f'Appended {len(lines)} guest command(s) to {args.bundle_id}; payload omitted.')


if __name__ == '__main__':
    main()
