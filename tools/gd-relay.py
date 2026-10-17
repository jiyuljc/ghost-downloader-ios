#!/usr/bin/env python3
"""把 Ghost Downloader 的回环服务转发到局域网。

Ghost Downloader 的 Browser Service（默认 127.0.0.1:14370）和 Aria2 RPC
（默认 127.0.0.1:16800）都只绑定回环地址，所以手机即使在同一个 Wi-Fi 下也连不上。
这个脚本换个地址监听，把 TCP 流量原样转发到回环端口——WebSocket 本质就是 TCP，
转发对上层协议完全透明。

    python gd-relay.py
    python gd-relay.py --listen-port 14371 --target-port 14370
    python gd-relay.py --listen-host 100.64.0.1     # 只绑 Tailscale 接口（推荐）

安全提醒：
  * 转发走的是明文 TCP，配对令牌会明文经过网络。请只在可信网络里用，
    或者只绑到 Tailscale / WireGuard 这类加密接口上（--listen-host）。
  * 桌面端看到的对端地址会变成 127.0.0.1，这是转发造成的，不影响功能。
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import sys

BUFFER_SIZE = 64 * 1024


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """单向搬运，直到任一端关闭。"""
    try:
        while True:
            data = await reader.read(BUFFER_SIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        with contextlib.suppress(Exception):
            writer.close()


async def bridge(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_host: str,
    target_port: int,
) -> None:
    try:
        server_reader, server_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as error:
        print(
            f"[gd-relay] 连不上 {target_host}:{target_port} —— {error}\n"
            f"[gd-relay] 请确认 Ghost Downloader 正在运行，且端口设置里 Browser Service 已启用。",
            file=sys.stderr,
        )
        client_writer.close()
        return

    await asyncio.gather(
        pump(client_reader, server_writer),
        pump(server_reader, client_writer),
        return_exceptions=True,
    )


async def serve(listen_host: str, listen_port: int, target_host: str, target_port: int) -> None:
    def handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> asyncio.Task:
        return asyncio.create_task(bridge(reader, writer, target_host, target_port))

    server = await asyncio.start_server(handler, listen_host, listen_port)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    print(f"[gd-relay] 监听 {addresses}  ->  {target_host}:{target_port}")
    print("[gd-relay] 在手机 App 的「电脑端地址」里填这台电脑的 IP 和上面这个端口。")
    print("[gd-relay] Ctrl+C 退出。")
    async with server:
        await server.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser(description="Ghost Downloader 回环服务转发")
    parser.add_argument("--listen-host", default="0.0.0.0", help="监听地址，默认 0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=14371, help="监听端口，默认 14371")
    parser.add_argument("--target-host", default="127.0.0.1", help="目标地址，默认 127.0.0.1")
    parser.add_argument(
        "--target-port",
        type=int,
        default=14370,
        help="目标端口，默认 14370（Browser Service；Aria2 RPC 是 16800）",
    )
    args = parser.parse_args()

    try:
        asyncio.run(serve(args.listen_host, args.listen_port, args.target_host, args.target_port))
    except KeyboardInterrupt:
        print("\n[gd-relay] 已退出")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
