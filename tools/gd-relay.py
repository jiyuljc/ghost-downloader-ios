#!/usr/bin/env python3
"""把 Ghost Downloader 的回环服务转发到局域网。

Ghost Downloader 的 Browser Service（默认 127.0.0.1:14370）和 Aria2 RPC
（默认 127.0.0.1:16800）都只绑定回环地址，所以手机即使在同一个 Wi-Fi 下也连不上。
这个脚本换个地址监听，把 TCP 流量原样转发到回环端口——WebSocket 本质就是 TCP，
转发对上层协议完全透明。

    python gd-relay.py
    python gd-relay.py --listen-port 14371 --target-port 14370
    python gd-relay.py --listen-host 192.168.0.106    # 只绑指定网卡
    python gd-relay.py --quiet                        # 只在接入/断开时打印

日志说明（排查手机连不上时看这里）：
  * 出现 `客户端接入 <手机IP>` —— 说明手机的数据包已经到电脑了，问题在协议或配对环节。
  * 手机上点了连接但这里**一直没有** `客户端接入` —— 说明包根本没到，
    去查：手机是否同一个 Wi-Fi/网段、iOS 的「本地网络」权限是否被拒、
    路由器是否开了 AP 隔离、Windows 防火墙是否放行。

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
import time

BUFFER_SIZE = 64 * 1024

VERBOSE = True


def log(text: str) -> None:
    print(f"[gd-relay] {time.strftime('%H:%M:%S')}  {text}", flush=True)


def warn(text: str) -> None:
    print(f"[gd-relay] {time.strftime('%H:%M:%S')}  {text}", file=sys.stderr, flush=True)


def describe(writer: asyncio.StreamWriter) -> str:
    info = writer.get_extra_info("peername")
    if not info or len(info) < 2:
        return "未知对端"
    return f"{info[0]}:{info[1]}"


async def pump(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    meter: dict[str, int],
    key: str,
) -> None:
    """单向搬运，直到任一端关闭。"""
    try:
        while True:
            data = await reader.read(BUFFER_SIZE)
            if not data:
                break
            meter[key] += len(data)
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
    client = describe(client_writer)
    log(f"客户端接入 {client}")

    try:
        server_reader, server_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as error:
        warn(f"连不上上游 {target_host}:{target_port} —— {error}")
        warn("请确认 Ghost Downloader 正在运行，且端口设置里 Browser Service 已启用。")
        with contextlib.suppress(Exception):
            client_writer.close()
        return

    log(f"上游已连接 {target_host}:{target_port}（来自 {client}）")

    meter = {"up": 0, "down": 0}
    upward = asyncio.create_task(pump(client_reader, server_writer, meter, "up"))
    downward = asyncio.create_task(pump(server_reader, client_writer, meter, "down"))

    # 任一方向结束就收摊。必须显式取消另一端，
    # 否则半关闭（对端只关了写方向）会让另一条 pump 一直挂着，
    # 上游 socket 永远不会释放。
    _, pending = await asyncio.wait({upward, downward}, return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)

    for writer in (client_writer, server_writer):
        with contextlib.suppress(Exception):
            writer.close()

    log(f"断开 {client}  上行 {meter['up']} B / 下行 {meter['down']} B")


async def serve(listen_host: str, listen_port: int, target_host: str, target_port: int) -> None:
    def handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> asyncio.Task:
        return asyncio.create_task(bridge(reader, writer, target_host, target_port))

    server = await asyncio.start_server(handler, listen_host, listen_port)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    log(f"监听 {addresses}  ->  {target_host}:{target_port}")
    log("在手机 App 的「电脑端地址」里填这台电脑的 IP 和上面这个端口。")
    log("手机上点连接时，这里会打印「客户端接入」；如果一直不打印，说明包没到电脑。")
    log("Ctrl+C 退出。")
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
    parser.add_argument("--quiet", action="store_true", help="只打印接入/断开/错误")
    args = parser.parse_args()

    global VERBOSE
    VERBOSE = not args.quiet

    try:
        asyncio.run(serve(args.listen_host, args.listen_port, args.target_host, args.target_port))
    except KeyboardInterrupt:
        print("\n[gd-relay] 已退出")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
