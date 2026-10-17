"""Manage main-server accounts locally; passwords never appear in command arguments."""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import secrets
import tempfile

def password_record(password):
    if not 12 <= len(password) <= 256:
        raise ValueError('Password must contain 12–256 characters.')
    salt = secrets.token_bytes(16)
    return {'algorithm': 'pbkdf2-sha256', 'iterations': 600000, 'salt': salt.hex(),
            'hash': hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, 600000).hex()}

def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.accounts-', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['set', 'disable', 'list'])
    parser.add_argument('--file', type=Path, default=Path(__file__).resolve().parents[1]/'runtime/server/users.json')
    parser.add_argument('--username')
    parser.add_argument('--role', choices=['admin', 'director', 'viewer'])
    parser.add_argument('--instance', action='append', help='Repeat for each authorized instance; * allows all.')
    parser.add_argument('--password', action='store_true', help='Prompt for a replacement password when updating an account.')
    args = parser.parse_args()
    if args.instance and (len(args.instance)>64 or any(not value or len(value)>256 or any(ord(c)<32 for c in value) for value in args.instance)):
        parser.error('At most 64 instance identifiers are allowed; each must contain 1–256 printable characters.')
    try: data = json.loads(args.file.read_text(encoding='utf-8'))
    except FileNotFoundError: data = {'version': 1, 'users': []}
    if data.get('version') != 1 or not isinstance(data.get('users'), list):
        parser.error('Invalid users file; existing file was preserved.')
    if args.action == 'list':
        for user in data['users']:
            print(json.dumps({key: user[key] for key in ['username', 'role', 'enabled', 'instances']}, ensure_ascii=False))
        return
    import re
    if not args.username or not re.fullmatch(r'[a-zA-Z0-9_.-]{2,64}', args.username):
        parser.error('--username must contain 2–64 ASCII letters, digits, underscores, dots or hyphens.')
    user = next((u for u in data['users'] if u['username'] == args.username), None)
    if args.action == 'disable':
        if user is None: parser.error('Account does not exist.')
        user['enabled'] = False
    else:
        if user is None:
            if not args.role or not args.instance: parser.error('New accounts require --role and --instance.')
            if len(data['users']) >= 256: parser.error('Account limit reached.')
            user = {'username': args.username}; data['users'].append(user)
        if args.role: user['role'] = args.role
        if args.instance: user['instances'] = sorted(set(args.instance))
        if 'password' not in user or args.password:
            first = getpass.getpass('New password (12–256 characters): ')
            if first != getpass.getpass('Repeat password: '): parser.error('Passwords differ; no changes saved.')
            try: user['password'] = password_record(first)
            except ValueError as error: parser.error(str(error))
        user['enabled'] = True
    save(args.file, data)
    print('Saved. The server reloads changes and revokes affected sessions within one second.')

if __name__ == '__main__': main()
