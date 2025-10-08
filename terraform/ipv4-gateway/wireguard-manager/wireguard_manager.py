import os
import ssl
import subprocess
import ipaddress
from string import Template

from aiohttp import web
from aiohttp.helpers import BasicAuth
from aiohttp.web import Response


class Peer:
    def __init__(self, public_key, ip):
        self.public_key = public_key
        self.ip = ip

g_peers = []
g_private_key = ""
g_public_key = ""

def calculate_ipv4_address(base_addr, offset):
    base_ip = ipaddress.IPv4Address(base_addr)
    new_ip = base_ip + offset
    return str(new_ip)

def generate_initial_wireguard_config():
    config_str = f"""
[Interface]
PrivateKey = {g_private_key}
Address = 10.0.0.1/8
ListenPort = 51820
    """

    try:
        with open("/etc/wireguard/wg0.conf", "w") as f:
            f.write(config_str)
    except IOError as e:
        return str(e)

    subprocess.run(["ip", "link", "del", "wg0"], check=False)
    cmd = ["wg-quick", "up", "wg0"]

    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        return result.stderr.decode()

    return None

def append_peer_to_wireguard_config(peer):
    peer_str = f"""
[Peer]
PublicKey = {peer.public_key}
AllowedIPs = {peer.ip}/32
    """

    try:
        with open("/etc/wireguard/wg0.conf", "a") as f:
            f.write(peer_str)
    except IOError as e:
        return str(e)

    # cmd = ["/usr/bin/bash", "-c", "wg syncconf wg0 <(wg-quick strip wg0)"]
    cmd = ["/usr/bin/bash", "-c", f"wg set wg0 peer '{peer.public_key}' allowed-ips {peer.ip}/32"]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        return result.stderr.decode()

    return None

def generate_private_key():
    try:
        private_key = subprocess.check_output(["wg", "genkey"]).decode().strip()
        public_key = subprocess.run(["wg", "pubkey"], input=private_key.encode(), stdout=subprocess.PIPE).stdout.decode().strip()
        return private_key, public_key, None
    except subprocess.CalledProcessError as e:
        return "", "", str(e)

async def wireguard_handler(request):
    wireguard_password = os.getenv("WIREGUARD_PASSWORD")
    endpoint = os.getenv("WIREGUARD_ENDPOINT")
    if not wireguard_password or not endpoint:
        return Response(body="500 Internal Server Error\nWIREGUARD_PASSWORD and WIREGUARD_ENDPOINT environment variables must be set", status=500)

    try:
        auth = BasicAuth.decode(request.headers['Authorization'])
    except (ValueError, KeyError) as e:
        return Response(body="401 Unauthorized\n", status=401, headers={"WWW-Authenticate": 'Basic realm="Restricted"'})

    if auth.login != "wireguard" or auth.password != wireguard_password:
        return Response(body="401 Unauthorized\n", status=401, headers={"WWW-Authenticate": 'Basic realm="Restricted"'})

    public_key = (await request.content.read()).decode()
    if not public_key:
        return Response(body="400 Bad Request\nbody as public key is required", status=400)

    try:
        ip = calculate_ipv4_address("10.0.0.1", len(g_peers) + 1)
    except Exception as e:
        return Response(body=f"500 Internal Server Error\n{str(e)}", status=500)

    new_peer = Peer(public_key, ip)
    g_peers.append(new_peer)

    err = append_peer_to_wireguard_config(new_peer)
    if err:
        return Response(body=f"500 Internal Server Error\n{err}", status=500)

    config_str = f"""
[Interface]
PrivateKey = XXXXXX
Address = {ip}

[Peer]
PublicKey = {g_public_key}
AllowedIPs = 0.0.0.0/0
Endpoint = {endpoint}:51820
PersistentKeepalive = 25
    """

    return Response(body=config_str, content_type="text/plain")

def on_starting(_):
    global g_private_key, g_public_key
    g_private_key, g_public_key, err = generate_private_key()
    if err:
        print(f"Error generating keys: {err}")
        exit(1)

    err = generate_initial_wireguard_config()
    if err:
        print(f"Error generating Wireguard config: {err}")
        exit(1)

app = web.Application()
app.add_routes([web.post('/wireguard', wireguard_handler)])

if __name__ == "__main__":
    on_starting(None)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile="server.crt", keyfile="server.key")

    web.run_app(app, ssl_context=context, port=443, host="::")