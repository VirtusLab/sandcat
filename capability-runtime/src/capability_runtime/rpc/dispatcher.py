"""JSON-RPC 2.0 dispatcher with agent and admin surface allowlists."""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any, Literal

from capability_runtime.discover import DiscoveryIntent
from capability_runtime.errors import CapabilityRuntimeError
from capability_runtime.l7_record import record_l7_flow
from capability_runtime.rpc import errors as rpc_errors
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.types import (
    AgentIdentity,
    CapabilityBundle,
    CapabilityRef,
    LeaseDecision,
    LeaseId,
)

AGENT_METHODS = frozenset(
    {
        "capability.check",
        "capability.lease",
        "capability.discover",
    }
)

ADMIN_METHODS = AGENT_METHODS | frozenset(
    {
        "capability.revoke",
        "capability.watch.poll",
        "capability.l7.record",
    }
)

_OPERATOR = AgentIdentity("operator")


class RpcDispatcher:
    """Route JSON-RPC requests to CapabilityRuntime with surface allowlists."""

    def __init__(
        self,
        runtime: CapabilityRuntime,
        *,
        surface: Literal["agent", "admin"],
        bound_agent_id: str,
        watcher: RouteDisappearanceWatcher | None = None,
    ) -> None:
        self._runtime = runtime
        self._surface = surface
        self._bound_agent_id = bound_agent_id
        self._watcher = watcher
        self._allowed = ADMIN_METHODS if surface == "admin" else AGENT_METHODS

    def handle(self, request: dict) -> dict:
        """Handle a JSON-RPC 2.0 request and return a response dict."""
        request_id = request.get("id")
        if request.get("jsonrpc") != "2.0":
            return self._error_response(request_id, rpc_errors.INVALID_REQUEST, "Invalid Request")
        method = request.get("method")
        if not isinstance(method, str):
            return self._error_response(request_id, rpc_errors.INVALID_REQUEST, "Invalid Request")
        if method not in self._allowed:
            return self._error_response(
                request_id, rpc_errors.METHOD_NOT_FOUND, "Method not found"
            )

        params = request.get("params") or {}
        if not isinstance(params, dict):
            return self._error_response(request_id, rpc_errors.INVALID_PARAMS, "Invalid params")

        try:
            result = self._dispatch(method, params)
        except CapabilityRuntimeError as exc:
            return self._error_response(request_id, rpc_errors.INTERNAL_ERROR, str(exc))
        except (KeyError, TypeError, ValueError) as exc:
            return self._error_response(request_id, rpc_errors.INVALID_PARAMS, str(exc))
        except Exception as exc:
            return self._error_response(request_id, rpc_errors.INTERNAL_ERROR, str(exc))

        return {"jsonrpc": "2.0", "result": result, "id": request_id}

    def _error_response(
        self, request_id: Any, code: int, message: str
    ) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "error": {"code": code, "message": message},
            "id": request_id,
        }

    def _dispatch(self, method: str, params: dict) -> dict:
        if method == "capability.check":
            return self._handle_check(params)
        if method == "capability.lease":
            return self._handle_lease(params)
        if method == "capability.discover":
            return self._handle_discover(params)
        if method == "capability.revoke":
            return self._handle_revoke(params)
        if method == "capability.watch.poll":
            return self._handle_watch_poll(params)
        if method == "capability.l7.record":
            return self._handle_l7_record(params)
        raise RuntimeError(f"unhandled allowed method: {method}")

    def _resolve_agent_id(self, params: dict) -> AgentIdentity:
        if self._surface == "agent":
            return AgentIdentity(self._bound_agent_id)
        agent_value = params.get("agent_id", self._bound_agent_id)
        return AgentIdentity(agent_value)

    def _handle_check(self, params: dict) -> dict:
        agent_id = self._resolve_agent_id(params)
        context = params.get("context", {})
        if not isinstance(context, dict):
            raise ValueError("context must be an object")
        bundle = self._runtime.check_current_capabilities(agent_id, context)
        return _serialize_bundle(bundle)

    def _handle_lease(self, params: dict) -> dict:
        agent_id = self._resolve_agent_id(params)
        capability_ref = CapabilityRef(params["capability_ref"])
        justification = params["justification"]
        decision = self._runtime.request_capability_lease(
            caller=agent_id,
            agent_id=agent_id,
            capability_ref=capability_ref,
            justification=justification,
        )
        return _serialize_lease_decision(decision)

    def _handle_discover(self, params: dict) -> dict:
        agent_id = self._resolve_agent_id(params)
        intent = DiscoveryIntent(query=params["query"])
        result = self._runtime.discover_capabilities(agent_id, intent)
        return {"capabilities": result.capabilities, "denied": result.denied}

    def _handle_revoke(self, params: dict) -> dict:
        target = _parse_revoke_target(self._runtime, params["target"])
        reason = params["reason"]
        self._runtime.revoke_capability(_OPERATOR, target, reason)
        return {"revoked": True}

    def _handle_watch_poll(self, params: dict) -> dict:
        if self._watcher is None:
            raise ValueError("route watcher not configured")
        self._watcher.poll_once()
        return {"polled": True}

    def _handle_l7_record(self, params: dict) -> dict:
        agent_id = self._resolve_agent_id(params)
        host = params["host"]
        method = params["method"]
        status = params["status"]
        trace_id = params.get("trace_id")
        recorded = record_l7_flow(
            self._runtime,
            agent_id,
            host=host,
            method=method,
            status=status,
            trace_id=trace_id,
        )
        return {"recorded": recorded}


def _parse_revoke_target(runtime: CapabilityRuntime, target: str) -> LeaseId | CapabilityRef:
    lease_id = LeaseId(target)
    if runtime.lease_manager.get_lease(lease_id) is not None:
        return lease_id
    return CapabilityRef(target)


def _serialize_bundle(bundle: CapabilityBundle) -> dict[str, Any]:
    return {
        "agent_id": bundle.agent_id.value,
        "issued_at": _serialize_datetime(bundle.issued_at),
        "expires_at": _serialize_datetime(bundle.expires_at),
        "tools": [_serialize_tool_capability(t) for t in bundle.tools],
        "networks": [_serialize_network_capability(n) for n in bundle.networks],
        "rules": [_serialize_named_capability(r) for r in bundle.rules],
        "skills": [_serialize_named_capability(s) for s in bundle.skills],
        "policies": [_serialize_named_capability(p) for p in bundle.policies],
        "hooks": [_serialize_named_capability(h) for h in bundle.hooks],
        "budgets": {
            "token_quota": bundle.budgets.token_quota,
            "action_quota": bundle.budgets.action_quota,
            "wall_time_ttl": _serialize_timedelta(bundle.budgets.wall_time_ttl),
        },
        "provenance": {
            "issuer": bundle.provenance.issuer,
            "policy_version": bundle.provenance.policy_version,
            "trace_id": bundle.provenance.trace_id,
        },
        "version": bundle.version,
    }


def _serialize_tool_capability(tool) -> dict[str, Any]:
    return {
        "ref": tool.ref.value,
        "name": tool.name,
        "lease_id": tool.lease_id.value if tool.lease_id else None,
        "quota": tool.quota,
        "expires_at": _serialize_datetime(tool.expires_at),
    }


def _serialize_network_capability(network) -> dict[str, Any]:
    return {
        "ref": network.ref.value,
        "name": network.name,
        "peer_id": network.peer_id,
        "network": network.network,
        "route_id": network.route_id,
        "lease_id": network.lease_id.value if network.lease_id else None,
        "quota": network.quota,
        "expires_at": _serialize_datetime(network.expires_at),
    }


def _serialize_named_capability(cap) -> dict[str, Any]:
    return {
        "ref": cap.ref.value,
        "name": cap.name,
        "lease_id": cap.lease_id.value if cap.lease_id else None,
    }


def _serialize_lease_decision(decision: LeaseDecision) -> dict[str, Any]:
    return {
        "lease_id": decision.lease_id.value,
        "capability_ref": decision.capability_ref.value,
        "agent_id": decision.agent_id.value,
        "quota": decision.quota,
        "token_budget": decision.token_budget,
        "risk_envelope": decision.risk_envelope,
        "expires_at": _serialize_datetime(decision.expires_at),
        "granted_at": _serialize_datetime(decision.granted_at),
    }


def _serialize_datetime(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.isoformat()


def _serialize_timedelta(value: timedelta | None) -> float | None:
    if value is None:
        return None
    return value.total_seconds()
