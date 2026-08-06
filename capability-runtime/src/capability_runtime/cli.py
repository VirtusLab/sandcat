"""Admin JSON-RPC client for the capability sidecar operator surface."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from capability_runtime.rpc.transports.unix import UnixRpcClient

DEFAULT_ADMIN_SOCKET = Path(
    os.environ.get("CAPABILITY_ADMIN_SOCKET", "/run/sandcat-capability/admin.sock")
)
DEFAULT_TRACE_FILE = Path(
    os.environ.get("CAPABILITY_TRACE_FILE", "/var/lib/sandcat/capability/trace.jsonl")
)

SUBCOMMAND_TO_METHOD = {
    "check": "capability.check",
    "lease": "capability.lease",
    "revoke": "capability.revoke",
    "watch": "capability.watch.poll",
}


def _resolve_method(name: str) -> str:
    if name.startswith("capability."):
        return name
    try:
        return SUBCOMMAND_TO_METHOD[name]
    except KeyError as exc:
        raise SystemExit(f"unknown command: {name}") from exc


def _admin_client() -> UnixRpcClient:
    return UnixRpcClient(DEFAULT_ADMIN_SOCKET)


def _call(method: str, params: dict) -> dict:
    response = _admin_client().call(method, params)
    if "error" in response:
        error = response["error"]
        print(
            f"RPC error {error.get('code')}: {error.get('message')}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return response["result"]


def _print_json(value: object) -> None:
    print(json.dumps(value, indent=2))


def _parse_context(raw: str) -> dict:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid --context JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise SystemExit("--context must be a JSON object")
    return parsed


def cmd_check(args: argparse.Namespace) -> None:
    params: dict = {"context": _parse_context(args.context)}
    if args.agent_id:
        params["agent_id"] = args.agent_id
    _print_json(_call("capability.check", params))


def cmd_lease(args: argparse.Namespace) -> None:
    params = {
        "capability_ref": args.ref,
        "justification": args.justification,
    }
    if args.agent_id:
        params["agent_id"] = args.agent_id
    _print_json(_call("capability.lease", params))


def cmd_revoke(args: argparse.Namespace) -> None:
    params: dict = {"target": args.ref, "reason": args.reason}
    if getattr(args, "close_policy", None):
        params["close_policy"] = args.close_policy
    _print_json(_call("capability.revoke", params))


def cmd_watch(args: argparse.Namespace) -> None:
    print(
        f"Watching capability events and route watcher (poll every {args.interval}s)...",
        file=sys.stderr,
    )
    trace_file = DEFAULT_TRACE_FILE
    trace_offset = 0
    if trace_file.exists():
        trace_offset = trace_file.stat().st_size

    while True:
        result = _call("capability.watch.poll", {})
        _print_json({"polled": result.get("polled", True), "ts": time.time()})

        if trace_file.exists():
            with trace_file.open("r") as fp:
                fp.seek(trace_offset)
                for line in fp:
                    trace_offset = fp.tell()
                    try:
                        event = json.loads(line)
                        if event.get("kind") == "capability":
                            event_type = event.get("event")
                            if event_type in (
                                "capability_leased",
                                "capability_revoked",
                                "lease_granted",
                                "physical_revocation",
                            ):
                                summary = {"event": event_type, "ts": event.get("ts")}
                                if "physical_sync" in event:
                                    summary["physical_sync"] = event["physical_sync"]
                                if "physical_revocation" in event:
                                    summary["physical_revocation"] = event[
                                        "physical_revocation"
                                    ]
                                if "capability_ref" in event:
                                    summary["capability_ref"] = event["capability_ref"]
                                if "lease_id" in event:
                                    summary["lease_id"] = event["lease_id"]
                                _print_json(summary)
                    except (json.JSONDecodeError, KeyError):
                        continue

        sys.stdout.flush()
        time.sleep(args.interval)


def cmd_demo(args: argparse.Namespace) -> None:
    agent_id = args.agent_id or "devcontainer-agent"
    print("=== capability demo: check ===", file=sys.stderr)
    before = _call("capability.check", {"agent_id": agent_id, "context": {}})
    _print_json(before)

    print("=== capability demo: lease cap-create-pr ===", file=sys.stderr)
    lease = _call(
        "capability.lease",
        {
            "agent_id": agent_id,
            "capability_ref": "cap-create-pr",
            "justification": "operator demo",
        },
    )
    _print_json(lease)

    print("=== capability demo: check after lease ===", file=sys.stderr)
    after_lease = _call("capability.check", {"agent_id": agent_id, "context": {}})
    _print_json(after_lease)

    print("=== capability demo: revoke cap-create-pr ===", file=sys.stderr)
    revoked = _call(
        "capability.revoke",
        {"target": "cap-create-pr", "reason": "demo complete"},
    )
    _print_json(revoked)

    print("=== capability demo: check after revoke ===", file=sys.stderr)
    after_revoke = _call("capability.check", {"agent_id": agent_id, "context": {}})
    _print_json(after_revoke)


def _add_agent_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--agent-id",
        "--agent",
        dest="agent_id",
        help="Agent identity (default: devcontainer-agent on admin surface)",
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="capability_runtime.cli")
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="Run capability.check")
    check.add_argument("--context", default="{}", help="Capability context JSON object")
    _add_agent_arg(check)
    check.set_defaults(handler=cmd_check)

    lease = subparsers.add_parser("lease", help="Run capability.lease")
    lease.add_argument("--ref", required=True, help="Capability reference")
    lease.add_argument("--justification", required=True, help="Lease justification")
    _add_agent_arg(lease)
    lease.set_defaults(handler=cmd_lease)

    revoke = subparsers.add_parser("revoke", help="Run capability.revoke")
    revoke.add_argument("--ref", required=True, help="Capability ref or lease id")
    revoke.add_argument("--reason", required=True, help="Revocation reason")
    revoke.add_argument(
        "--close-policy",
        choices=["immediate", "drain", "drain_deadline", "deny_new"],
        default=None,
    )
    revoke.set_defaults(handler=cmd_revoke)

    watch = subparsers.add_parser("watch", help="Poll capability.watch.poll in a loop")
    watch.add_argument(
        "--interval",
        type=float,
        default=float(os.environ.get("CAPABILITY_WATCH_INTERVAL", "5")),
        help="Seconds between poll calls",
    )
    watch.set_defaults(handler=cmd_watch)

    demo = subparsers.add_parser("demo", help="Run a check/lease/revoke smoke demo")
    _add_agent_arg(demo)
    demo.set_defaults(handler=cmd_demo)

    for method in SUBCOMMAND_TO_METHOD.values():
        alias = subparsers.add_parser(method, help=f"Alias for {method}")
        if method == "capability.check":
            alias.add_argument("--context", default="{}")
            _add_agent_arg(alias)
            alias.set_defaults(handler=cmd_check)
        elif method == "capability.lease":
            alias.add_argument("--ref", required=True)
            alias.add_argument("--justification", required=True)
            _add_agent_arg(alias)
            alias.set_defaults(handler=cmd_lease)
        elif method == "capability.revoke":
            alias.add_argument("--ref", required=True)
            alias.add_argument("--reason", required=True)
            alias.add_argument(
                "--close-policy",
                choices=["immediate", "drain", "drain_deadline", "deny_new"],
                default=None,
            )
            alias.set_defaults(handler=cmd_revoke)
        elif method == "capability.watch.poll":
            alias.add_argument(
                "--interval",
                type=float,
                default=float(os.environ.get("CAPABILITY_WATCH_INTERVAL", "5")),
            )
            alias.set_defaults(handler=cmd_watch)

    return parser


def main(argv: list[str] | None = None) -> None:
    args = _build_parser().parse_args(argv)
    args.handler(args)


if __name__ == "__main__":
    main()
