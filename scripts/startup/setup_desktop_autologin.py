#!/usr/bin/env python3
"""Enable GDM automatic login without restarting the desktop."""
import argparse
import configparser
import os
from pathlib import Path
import pwd
import re
import shutil
import tempfile


def configure(path, user):
    original = path.read_text()
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(original)
    section = re.search(r'(?ms)^\[daemon\][ \t]*\n(.*?)(?=^\[|\Z)', original)
    if section is None:
        raise ValueError(f'Missing [daemon] section in {path}')
    body = section[1]
    for key, value in [('AutomaticLoginEnable', 'true'), ('AutomaticLogin', user)]:
        pattern = rf'(?m)^[ \t]*{key}[ \t]*=.*$'
        setting = f'{key}={value}'
        if re.search(pattern, body):
            body = re.sub(pattern, lambda _: setting, body)
        else:
            body = body.rstrip('\n') + '\n' + setting + '\n\n'
    content = original[:section.start(1)] + body + original[section.end(1):]
    if content == original:
        print(f'[login] Automatic login already configured for {user}.')
        return

    backup = path.with_name('custom.conf.before-zephyr-autologin')
    if not backup.exists():
        shutil.copy2(path, backup)
    metadata = path.stat()
    fd, temporary = tempfile.mkstemp(prefix='.custom-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), metadata.st_mode & 0o777)
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'[login] Automatic login configured for {user}; backup: {backup}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('user', nargs='?', default=os.getenv('SUDO_USER'))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run with sudo: sudo python3 setup_desktop_autologin.py [desktop-user]')
    if not args.user or args.user in {'root', 'gdm'}:
        parser.error('Specify the normal desktop user, e.g. nvidia')
    try:
        pwd.getpwnam(args.user)
    except KeyError:
        parser.error(f'User does not exist: {args.user}')
    configure(Path('/etc/gdm3/custom.conf'), args.user)
    print('[login] Takes effect at the next boot; the current desktop was not restarted.')


if __name__ == '__main__':
    main()
