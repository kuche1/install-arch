#! /usr/bin/env python3

import subprocess
import json

VOL_GR_NAME = 'myVolGr'
LV_NAME = 'myRootVol'

SECTOR_SIZE = 512 # TODO this might be wrong

def term(cmd:list[str], *a, **kw):
    print(f'+ running: {" ".join(cmd)}')
    return subprocess.run(cmd, check=True, *a, **kw)

def term_out(cmd:list[str]):
    return term(cmd, capture_output=True).stdout.decode()

class Device:
    def __init__(s, path, cur_part):
        s.path = path
        s.part = cur_part
        s.used_space = 0
        s.total_space = int(term_out(['blockdev', '--getsize64', path]))
        s.free_space = s.total_space - s.used_space
    def __lt__(s, other):
        return s.free_space < other.free_space
    def use_space(s, size):
        remainder = size % SECTOR_SIZE
        if remainder != 0:
            size += (SECTOR_SIZE - remainder)
        s.used_space += size
        s.free_space -= size

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

devices = selected_devices
assert len(devices) > 0

print(f'Select boot device: {devices}')
dev = input('> ')

boot_dev = dev
devices.remove(boot_dev)

term(['parted', '-s', boot_dev, 'mklabel', 'gpt'])
boot_dev_bytes = 1024 * 1024 * 512 # 512 MiB
term(['parted', '-s', boot_dev, 'mkpart', 'primary', 'fat32', '0%', f'{boot_dev_bytes}B'])
term(['parted', '-s', boot_dev, 'set', '1', 'esp', 'on'])

term(['mkfs.fat', '-F32', f'{boot_dev}1'])

devs = [Device(boot_dev, 2)]
devs[0].use_space(boot_dev_bytes)
for dev in devices:
    term(['parted', '-s', dev, 'mklabel', 'gpt'])
    devs.append(Device(dev, 1))

cur_md = 0

while True:
    if len(devs) <= 1:
        break
    
    smallest = min(devs)
    size = smallest.free_space

    for dev in devs:
        #term(['parted', '-s', dev.path, 'mkpart', 'primary', 'ext4', f'{dev.used_space}B', f'{dev.used_space+size}B'])
        term(['parted', '-s', dev.path, 'mkpart', 'primary', f'{dev.used_space}B', f'{dev.used_space+size}B']) # TODO u can try changing the first `used_space` call to `used_space+1`
        term(['parted', '-s', dev.path, 'set', dev.part, 'raid', 'on'])
        dev.use_space(size)

    # for dev in devs:
    #     term(['mkfs.ext4', '-F', f'{dev.path}{dev.part}'])

    term(['mdadm', '-Cv', '-l0', '-c64', f'-n{len(devs)}', f'/dev/md{cur_md}'] + [f'{dev.path}{dev.part}' for dev in devs])
    cur_md += 1

    for dev in devs:
        dev.part += 1

    devs.remove(smallest)

    to_delete = []
    for dev in devs:
        if dev.free_space == 0:
            to_delete.append(dev)
    
    for dev in to_delete:
        devs.remove(dev)

parts = [f'/dev/md{x}' for x in range(cur_md)] + devs
for part in parts:
    #term(['mkfs.ext4', '-F', f'{part}'])
    term(['pvcreate', part])

term(['vgcreate', VOL_GR_NAME] + parts)

term(['lvcreate', '--yes', '-l', '100%FREE', VOL_GR_NAME, '-n', LV_NAME])

term(['mkfs.ext4', '-F', f'/dev/mapper/{VOL_GR_NAME}-{LV_NAME}'])
