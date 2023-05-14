#! /usr/bin/env python3

import subprocess
import json
import sys

VOL_GR_NAME = 'myVolGr'
LV_NAME = 'myRootVol'

def term(cmd:list[str], *a, **kw):
    cmd = [str(c) for c in cmd]
    print(f'+ running `{" ".join(cmd)}`')
    return subprocess.run(cmd, check=True, *a, **kw)

def term_out(cmd:list[str]):
    return term(cmd, capture_output=True).stdout.decode()

assert len(sys.argv) == 2
boot_device = sys.argv[1]

out = term_out(['lsblk', '--json'])
devices = json.loads(out)
block_devices = devices['blockdevices']

devices = []
for dev in block_devices:
    name = dev['name']
    dev = f'/dev/{name}'
    devices.append(dev)

devices.remove(boot_device)

selected_devices = []
while True:
    print(f'Select additional devices (leave empty when done): {devices}')
    dev = input('> ')
    if dev == '':
        break

    devices.remove(dev)
    selected_devices.append(dev)

devs = selected_devices
assert len(devs) > 0

devs = devs

print(' '.join(devs))
