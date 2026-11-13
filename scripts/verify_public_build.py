#!/usr/bin/env python3
"""Reject update configuration in public source plists or built app bundles."""
from pathlib import Path
import plistlib
import sys


def verify(path):
    path = Path(path)
    if path.is_dir():
        path = path / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    if info.get('NJPDistributionEdition') != 'public':
        raise ValueError('Expected the public edition')
    forbidden = ['SUFeedURL', 'SUPublicEDKey', 'NJPUpdateAccessToken']
    if any(key in info for key in forbidden):
        raise ValueError('Public builds must not contain an update feed, signing key or access token')
    if any(info.get(key) is not False for key in ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate']):
        raise ValueError('Automatic updates must be explicitly disabled')


if __name__ == '__main__':
    verify(sys.argv[1])
    print('Public edition verified: no update configuration or access token.')
