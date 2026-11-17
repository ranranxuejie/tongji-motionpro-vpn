"""MotionPro VPN 客户端助手：确保隧道已建立，并让请求走路由表而不是系统代理。

用法：
    python motionpro_client.py check                 # 检查 VPN / DNS / 目标站点
    python motionpro_client.py up                    # 只连 VPN
    python motionpro_client.py down                  # 断开
    python motionpro_client.py get https://host/path # 发 GET（自动 ensure_vpn）

配置：同目录 motionpro.env，或 %USERPROFILE%\\.tongji-motionpro-vpn\\motionpro.env
    MOTIONPRO_HOST / MOTIONPRO_PORT / MOTIONPRO_USER / MOTIONPRO_PASS
    MOTIONPRO_TARGETS=agi.example.edu.cn,10.67.0.0/16
    MOTIONPRO_HEADERS=Authorization: Bearer xxx   （可选，按行分割亦可）
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent


def _config_candidates() -> list[Path]:
    return [
        Path.cwd() / "motionpro.env",
        Path.home() / ".tongji-motionpro-vpn" / "motionpro.env",
        HERE / "motionpro.env",
    ]


def load_config() -> dict[str, str]:
    cfg: dict[str, str] = {}
    for path in _config_candidates():
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            cfg[key.strip()] = value.strip().strip('"').strip("'")
        break
    for key in list(cfg):
        if os.environ.get(key):
            cfg[key] = os.environ[key]
    return cfg


CFG = load_config()

# 有些域名同时有 AAAA 记录，IPv6 会绕过 IPv4 的 VPN 隧道。
# 默认强制 IPv4；需要原生双栈时设 MOTIONPRO_FORCE_IPV4=0。
_FORCE_IPV4 = (os.environ.get("MOTIONPRO_FORCE_IPV4") or CFG.get("MOTIONPRO_FORCE_IPV4", "1")) != "0"


def _force_ipv4_getaddrinfo() -> None:
    original = socket.getaddrinfo

    def wrapper(host, port, family=0, *args, **kwargs):
        if family in (0, socket.AF_UNSPEC):
            family = socket.AF_INET
        return original(host, port, family, *args, **kwargs)

    socket.getaddrinfo = wrapper  # type: ignore[assignment]


if _FORCE_IPV4:
    _force_ipv4_getaddrinfo()


def cfg(name: str, default: str = "") -> str:
    return os.environ.get(name) or CFG.get(name, default)


def targets() -> list[str]:
    raw = cfg("MOTIONPRO_TARGETS")
    return [t for t in raw.replace(";", ",").replace(" ", ",").split(",") if t]


def _run_ps(script: str, *args: str, timeout: int = 300) -> subprocess.CompletedProcess:
    cmd = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(HERE / script), *args,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def vpn_ip() -> str:
    # 注意：MotionPro 的 SSTP 接口不出现在 Get-NetAdapter（那里只有一个常年
    # Disconnected 的 TAP 网卡），必须用 Get-NetIPInterface 按别名找。
    ps = (
        "Get-NetIPInterface -AddressFamily IPv4 |"
        " Where-Object { $_.InterfaceAlias -like '*Array Networks*' } |"
        " ForEach-Object { (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4"
        " | Select-Object -First 1).IPAddress } |"
        " Where-Object { $_ -and $_ -notlike '169.254.*' } | Select-Object -First 1"
    )
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps],
        capture_output=True, text=True, timeout=30,
    )
    return (out.stdout or "").strip().splitlines()[0] if out.stdout.strip() else ""


def route_uses_vpn(ip: str) -> bool:
    ps = (
        f"$r = Find-NetRoute -RemoteIPAddress '{ip}' -ErrorAction SilentlyContinue;"
        "if ($r) { $r[0].InterfaceAlias }"
    )
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps],
        capture_output=True, text=True, timeout=30,
    )
    return "Array Networks" in (out.stdout or "")


def _probe_ip(prefix: str) -> str:
    ip, _, length = prefix.partition("/")
    if not length or int(length) >= 32:
        return ip
    parts = ip.split(".")
    parts[3] = str(int(parts[3]) + 1)
    return ".".join(parts)


def ensure_vpn() -> None:
    if vpn_ip():
        return
    print("[vpn] not connected, bringing it up ...")
    proc = _run_ps("vpn.ps1", "up")
    print((proc.stdout or "").strip())
    if proc.returncode != 0:
        raise SystemExit((proc.stderr or "vpn up failed").strip())


def session() -> requests.Session:
    s = requests.Session()
    # 关键：Windows 上常开着系统代理（Clash 等），requests 会把内网目标交给它，
    # 导致 ConnectionAbortedError(10053)。这里默认忽略系统代理，走路由表。
    s.trust_env = False
    for header in (cfg("MOTIONPRO_HEADERS") or "").splitlines():
        if ":" in header:
            k, v = header.split(":", 1)
            s.headers[k.strip()] = v.strip()
    s.verify = True
    return s


def check() -> int:
    ip = vpn_ip()
    print(f"[vpn] adapter ip : {ip or '(not connected)'}")
    ok = bool(ip)
    hosts: list[str] = []
    for t in targets():
        if "/" in t:
            probe = _probe_ip(t)
            via = route_uses_vpn(probe)
            print(f"[vpn] {t:<22} probe={probe:<15} via_vpn={via}")
            ok = ok and via
        else:
            hosts.append(t)
    for t in hosts:
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(t, 443)})
            print(f"[vpn] {t:<34} dns={', '.join(ips)}")
        except OSError as exc:
            print(f"[vpn] {t:<34} dns FAILED {exc}")
            ok = False
    for t in hosts:
        try:
            r = session().get(f"https://{t}/", timeout=20)
            print(f"[vpn] https://{t}/ -> {r.status_code} ({len(r.content)} bytes)")
        except Exception as exc:  # noqa: BLE001
            print(f"[vpn] https://{t}/ -> FAILED {type(exc).__name__}: {exc}")
            ok = False
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]
    if cmd == "check":
        return check()
    if cmd == "up":
        proc = _run_ps("vpn.ps1", "up")
        print((proc.stdout or "").strip())
        return proc.returncode
    if cmd == "down":
        proc = _run_ps("vpn.ps1", "down")
        print((proc.stdout or "").strip())
        return proc.returncode
    if cmd == "get":
        ensure_vpn()
        r = session().get(argv[2], timeout=30)
        print(r.status_code)
        try:
            print(json.dumps(r.json(), ensure_ascii=False, indent=2)[:4000])
        except ValueError:
            print(r.text[:2000])
        return 0 if r.ok else 1
    print(f"unknown command: {cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
