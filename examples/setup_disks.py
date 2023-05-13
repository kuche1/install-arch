#! /usr/bin/env python3

import subprocess
import json

VOL_GR_NAME = 'myVolGr'
LV_NAME = 'myRootVol'

def term(cmd:list[str], *a, **kw):
    cmd = [str(c) for c in cmd]
    print(f'+ running `{" ".join(cmd)}`')
    return subprocess.run(cmd, check=True, *a, **kw)

def term_out(cmd:list[str]):
    return term(cmd, capture_output=True).stdout.decode()

class Device:
    def __init__(s, path, cur_part, taken_space):
        s.path = path
        s.part = cur_part
        s.used_space = 0
        s.taken_space = taken_space # in GiB
    # def __lt__(s, other):
    #     return s.free_space < other.free_space
    # def use_space(s, size):
    #     s.used_space += size
    #     s.free_space -= size
    def get_cur_space(s)->str:
        if s.taken_space == 0:
            return '0%'
        return f'{s.taken_space}GiB'
    def inc_cur_space(s, size:int)->str:
        s.taken_space += size
        return f'{s.taken_space}GiB'
    
    def get_cur_part(s):
        return f'{s.path}{s.part}'

out = term_out(['lsblk', '--json'])
devices = json.loads(out)
block_devices = devices['blockdevices']

devices = []
for dev in block_devices:
    name = dev['name']
    dev = f'/dev/{name}'
    devices.append(dev)

selected_devices = []
while True:
    print(f'Select device (leave empty when done): {devices}')
    dev = input('> ')
    if dev == '':
        break

    devices.remove(dev)
    selected_devices.append(dev)

devs = selected_devices
assert len(devices) > 0

for dev in devs:
    term(['parted', '-s', dev, 'mklabel', 'gpt'])

print(f'Select boot device: {devs}')
dev = input('> ')

boot_dev = dev
devs.remove(boot_dev)

boot_part = f'{boot_dev}1'

term(['parted', '-s', boot_dev, 'mkpart', 'primary', 'fat32', '0%', '1GiB'])
term(['parted', '-s', boot_dev, 'set', '1', 'esp', 'on'])
term(['mkfs.fat', '-F32', f'{boot_dev}1'])

devs = [Device(dev, 0, 0) for dev in devs] + [Device(boot_dev, 1, 1)]

cur_md = 0

while True:
    if len(devs) <= 1:
        break

    print(term_out(['lsblk']))
    size = input('Select size for next raid0 in GiB (you should select the actual size - 1) (example: 79): ')
    assert int(size) == float(size) # needs to be an int
    size = int(size)
    for dev in devs:
        term(['parted', '-s', dev.path, 'mkpart', 'primary', dev.get_cur_space(), dev.inc_cur_space(size)])
        dev.part += 1
        #term(['parted', '-s', dev.path, 'set', dev.part, 'raid', 'on'])

    # TODO no need to specifu the blocksize with `-c64`
    term(['mdadm', '-Cv', '-l0', '-c64', f'-n{len(devs)}', f'/dev/md{cur_md}'] + [dev.get_cur_part() for dev in devs])
    cur_md += 1

    while True:
        print(term_out(['lsblk']))
        paths = [dev.path for dev in devs]
        print(f'Select which device is now full (leave empty to stop): {paths}')
        dev = input('> ')
        if dev == '':
            break
        del devs[paths.index(dev)]
        paths.remove(dev)

mds = []
for md in range(cur_md):
    md = f'/dev/md{md}'
    mds.append(md)
    # term(['mkfs.ext4', md])

for md in mds:
    term(['pvcreate', md])

for dev in devs:
    term(['parted', '-s', dev.path, 'mkpart', 'primary', dev.get_cur_space(), '100%'])
    # TODO cur_space is now out of data
    dev.part += 1

term(['vgcreate', 'myVolGr'] + mds + [dev.get_cur_part() for dev in devs]) # include all raid0s and the empty space of the last disk (if there is one)

term(['lvcreate', '--yes', '-l', '100%FREE', 'myVolGr', '-n', 'myRootVol'])

term(['mkfs.ext4', '-F', '/dev/mapper/myVolGr-myRootVol'])

term(['mount', '/dev/mapper/myVolGr-myRootVol', '/mnt'])

term(['mkdir', '-p', '/mnt/boot/efi'])

term(['mount', boot_part, '/mnt/boot/efi'])
