#!/usr/bin/env python3
"""Exercise the real OBCI/libobclient TLS handshake without an OceanBase tenant.

Usage: python3 tests/oracle-tls-wire.py /path/to/hammerdbcli /path/to/libhdbobcitls.so
The fixture refuses DB authentication after TLS; this is not a workload test.
"""
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def certificate(root, name, ca=None, usage=None, san=None):
    key, pem = root / (name + '.key'), root / (name + '.pem')
    if ca is None:
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=' + name, '-keyout', str(key), '-out', str(pem))
    else:
        csr, ext = root / (name + '.csr'), root / (name + '.ext')
        run('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + name,
            '-keyout', str(key), '-out', str(csr))
        ext.write_text('extendedKeyUsage=' + usage + '\n' + ('subjectAltName=' + san + '\n' if san else ''))
        run('openssl', 'x509', '-req', '-days', '1', '-in', str(csr), '-CA', str(root / (ca + '.pem')),
            '-CAkey', str(root / (ca + '.key')), '-CAcreateserial', '-extfile', str(ext), '-out', str(pem))


def packet(data, sequence=0):
    return len(data).to_bytes(3, 'little') + bytes([sequence]) + data


def receive(sock):
    def exact(length):
        data = b''
        while len(data) < length:
            part = sock.recv(length - len(data))
            if not part:
                return b''
            data += part
        return data
    header = exact(4)
    return exact(int.from_bytes(header[:3], 'little')) if header else b''


def check_case(root, cli, library, name, *, mutual=False, client=False,
               ca='ca', tls=True, host='127.0.0.1', cipher='', key='client', capath=False, workers=1):
    result = {'tls': False, 'auth': False, 'client_certificate': False, 'plaintext_auth': False}
    listener = socket.socket()
    listener.bind((host, 0))
    listener.listen()
    listener.settimeout(10)
    port = listener.getsockname()[1]

    def serve_connection(conn):
        try:
            with conn:
                conn.settimeout(10)
                capabilities = 0x00088201 | (0x800 if tls else 0)
                handshake = (b'\x0a5.7.25-OceanBase\x00' + struct.pack('<I', 1) + b'12345678\x00' +
                             struct.pack('<H', capabilities & 0xffff) + b'\x2d\x02\x00' +
                             struct.pack('<H', capabilities >> 16) + b'\x15' + b'\x00' * 10 +
                             b'123456789012\x00mysql_native_password\x00')
                conn.sendall(packet(handshake))
                request = receive(conn)
                if not request:
                    return
                if not tls or len(request) != 32 or not (int.from_bytes(request[:4], 'little') & 0x800):
                    result['plaintext_auth'] = len(request) > 32
                    return
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(root / 'server.pem', root / 'server.key')
                if mutual:
                    context.verify_mode = ssl.CERT_REQUIRED
                    context.load_verify_locations(root / 'ca.pem')
                with context.wrap_socket(conn, server_side=True) as secure:
                    result['tls'] = True
                    result['client_certificate'] = bool(secure.getpeercert())
                    result['auth'] = bool(receive(secure))
                    if result['auth']:
                        secure.sendall(packet(b'\xff\x15\x04#28000TLS fixture refuses database authentication', 3))
        except (ssl.SSLError, ConnectionError, OSError) as error:
            result['transport_error'] = type(error).__name__

    observations = []

    def serve():
        with listener:
            for _ in range(workers):
                try:
                    conn, _ = listener.accept()
                except OSError:
                    observations.append({'timeout': True})
                    return
                result.update(tls=False, auth=False, client_certificate=False, plaintext_auth=False)
                serve_connection(conn)
                observations.append(dict(result))

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    state = root / name
    state.mkdir(mode=0o700)
    env = dict(os.environ, TMP=str(state), TMPDIR=str(state), HDB_TLS_HOST=host,
               HDB_TLS_PORT=str(port), HDB_TLS_LIBRARY=str(library), HDB_TLS_CIPHER=cipher, HDB_TLS_WORKERS=str(workers),
               HDB_TLS_CA=str(root / (ca + '.pem')) if ca and not capath else '',
               HDB_TLS_CAPATH=str(root / 'trust') if capath else '',
               HDB_TLS_CERT=str(root / 'client.pem') if client else '',
               HDB_TLS_KEY=str(root / (key + '.key')) if client else '')
    helper = Path(__file__).resolve().parent / 'helpers/oceanbase-oracle-tls-client.tcl'
    completed = subprocess.run([str(cli), 'auto', str(helper)], cwd=cli.parent, env=env,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    thread.join(11)
    if thread.is_alive():
        raise AssertionError(name + ': fixture did not stop')
    if completed.returncode or 'TLS_FIXTURE_CONNECT_REJECTED' not in completed.stdout:
        raise AssertionError(name + ': CLI failed before the expected handshake\n' + completed.stdout[-2000:])
    expected = name in ('one_way', 'encryption_only', 'two_way', 'ca_directory', 'threaded_mutual')
    assert len(observations) == workers, (name, observations)
    for observation in observations:
        assert observation.get('auth') == expected, (name, observation, completed.stdout[-1500:])
        assert not observation.get('plaintext_auth'), (name, observation)
        if expected:
            assert observation['tls'], (name, observation)
        if mutual and expected:
            assert observation['client_certificate'], (name, observation)
    print(json.dumps({'case': name, 'passed': True, 'connections': workers, 'observations': observations}), flush=True)



def main():
    cli, library = (Path(arg).resolve() for arg in sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix='hdb obci tls ') as temporary:
        root = Path(temporary)
        certificate(root, 'ca')
        certificate(root, 'other-ca')
        certificate(root, 'server', 'ca', 'serverAuth', 'DNS:localhost,IP:127.0.0.1')
        certificate(root, 'client', 'ca', 'clientAuth')
        trust = root / 'trust'
        trust.mkdir()
        (trust / 'ca.pem').write_bytes((root / 'ca.pem').read_bytes())
        run('openssl', 'rehash', str(trust))
        for name, options in (
            ('one_way', {}), ('encryption_only', {'ca': None}),
            ('two_way', {'mutual': True, 'client': True}),
            ('ca_directory', {'capath': True}),
            ('threaded_mutual', {'mutual': True, 'client': True, 'workers': 2}),
            ('wrong_ca', {'ca': 'other-ca'}), ('wrong_hostname', {'host': '127.0.0.2'}),
            ('missing_client_certificate', {'mutual': True}),
            ('mismatched_client_key', {'mutual': True, 'client': True, 'key': 'server'}),
            ('invalid_cipher', {'cipher': 'NO_SUCH_CIPHER'}), ('server_without_tls', {'tls': False}),
        ):
            check_case(root, cli, library, name, **options)
    print('OBCI_TLS_WIRE_OK 11', flush=True)


if __name__ == '__main__':
    main()
