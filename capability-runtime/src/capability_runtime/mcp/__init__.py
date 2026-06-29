"""Minimal MCP subset for capability meta-tools."""

from capability_runtime.mcp.bridge import run_mcp_bridge
from capability_runtime.mcp.server import McpServer

__all__ = ["McpServer", "run_mcp_bridge"]
