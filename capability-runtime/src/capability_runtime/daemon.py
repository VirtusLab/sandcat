"""Sidecar daemon: CapabilityRuntime, route watcher, dual Unix socket RPC."""

from __future__ import annotations

import json
import os
import signal
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient, NetBirdClient, RestNetBirdClient
from capability_runtime.network import NetworkBinding, sync_mode_from_catalog
from capability_runtime.rpc.dispatcher import RpcDispatcher
from capability_runtime.rpc.transports.unix import UnixRpcServer
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import CapabilityRef


@dataclass(frozen=True)
class DaemonConfig:
    catalog_path: Path
    agent_socket: Path
    admin_socket: Path
    trace_file: Path
    agent_id: str = "devcontainer-agent"
    trace_id: str = "capability-sidecar"
    seed: int = 42
    watch_interval: float = 5.0
    mock_netbird: bool = False

    @classmethod
    def from_env(cls) -> DaemonConfig:
        catalog = os.environ.get("CAPABILITY_CATALOG_JSON")
        if not catalog:
            raise RuntimeError("CAPABILITY_CATALOG_JSON is required")
        return cls(
            catalog_path=Path(catalog),
            agent_socket=Path(
                os.environ.get(
                    "CAPABILITY_AGENT_SOCKET",
                    "/run/sandcat-capability/agent.sock",
                )
            ),
            admin_socket=Path(
                os.environ.get(
                    "CAPABILITY_ADMIN_SOCKET",
                    "/run/sandcat-capability/admin.sock",
                )
            ),
            trace_file=Path(
                os.environ.get(
                    "CAPABILITY_TRACE_FILE",
                    "/var/lib/sandcat/capability/trace.jsonl",
                )
            ),
            agent_id=os.environ.get("SANDCAT_AGENT_ID", "devcontainer-agent"),
            trace_id=os.environ.get("CAPABILITY_TRACE_ID", "capability-sidecar"),
            watch_interval=float(os.environ.get("CAPABILITY_WATCH_INTERVAL", "5")),
            mock_netbird=os.environ.get("CAPABILITY_MOCK_NETBIRD") == "1",
        )


def build_netbird_client(config: DaemonConfig) -> NetBirdClient:
    if config.mock_netbird:
        return MockNetBirdClient()
    return RestNetBirdClient.from_settings()


def build_runtime(config: DaemonConfig, netbird_client: NetBirdClient) -> CapabilityRuntime:
    config.trace_file.parent.mkdir(parents=True, exist_ok=True)
    return CapabilityRuntime(
        config.trace_file,
        config.trace_id,
        config.seed,
        netbird_client=netbird_client,
    )


def load_catalog_into_runtime(runtime: CapabilityRuntime, catalog_path: Path) -> None:
    """Register tool and network capabilities from a JSON catalog file."""
    data = json.loads(catalog_path.read_text())
    for entry in data.get("capabilities", []):
        name = entry["name"]
        ref = CapabilityRef(entry["ref"])
        cap_type = entry.get("type", "tool")
        if cap_type == "network":
            route_id = entry.get("route_id")
            if isinstance(route_id, str):
                route_id = route_id.strip() or None
                if route_id and route_id.lower() in {
                    "route-placeholder",
                    "peer-placeholder",
                    "placeholder",
                }:
                    route_id = None
            binding = NetworkBinding(
                ref,
                entry["peer_id"],
                entry["network"],
                route_id,
                sync_mode_from_catalog(entry),
            )
            runtime.register_network_capability(
                name,
                ref,
                binding,
                LifecycleState.DECLARED,
            )
        else:
            if runtime.catalog.get_by_name(name) is None:
                runtime.catalog.register(name, ref, LifecycleState.DECLARED)


class _WatcherPollThread:
    def __init__(self, watcher: RouteDisappearanceWatcher, interval: float) -> None:
        self._watcher = watcher
        self._interval = interval
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run,
            name="route-watcher",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def _run(self) -> None:
        while not self._stop.is_set():
            self._watcher.poll_once()
            self._stop.wait(self._interval)


class CapabilityDaemon:
    """Run runtime, route watcher, and agent/admin RPC sockets."""

    def __init__(self, config: DaemonConfig) -> None:
        self._config = config
        self._netbird_client = build_netbird_client(config)
        self._runtime = build_runtime(config, self._netbird_client)
        load_catalog_into_runtime(self._runtime, config.catalog_path)
        self._watcher = RouteDisappearanceWatcher(self._runtime, self._netbird_client)
        self._watcher_thread = _WatcherPollThread(self._watcher, config.watch_interval)
        self._agent_server = UnixRpcServer(
            config.agent_socket,
            RpcDispatcher(
                self._runtime,
                surface="agent",
                bound_agent_id=config.agent_id,
            ),
            # Sidecar runs as root; agent container connects as vscode on shared volume.
            socket_mode=0o666,
        )
        self._admin_server = UnixRpcServer(
            config.admin_socket,
            RpcDispatcher(
                self._runtime,
                surface="admin",
                bound_agent_id="operator",
                watcher=self._watcher,
            ),
            socket_mode=0o600,
        )
        self._running = False

    @property
    def runtime(self) -> CapabilityRuntime:
        return self._runtime

    def start(self) -> None:
        if self._running:
            return
        self._watcher_thread.start()
        self._agent_server.start()
        self._admin_server.start()
        self._running = True

    def stop(self) -> None:
        if not self._running:
            return
        self._admin_server.stop()
        self._agent_server.stop()
        self._watcher_thread.stop()
        self._running = False

    def wait(self) -> None:
        while self._running:
            time.sleep(0.5)


def run_daemon(config: DaemonConfig | None = None) -> None:
    daemon = CapabilityDaemon(config or DaemonConfig.from_env())
    daemon.start()

    def _shutdown(_signum: int, _frame: object) -> None:
        daemon.stop()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    daemon.wait()


def main() -> None:
    run_daemon()


if __name__ == "__main__":
    main()
