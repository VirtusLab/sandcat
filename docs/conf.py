# -*- coding: utf-8 -*-
#
# sandcat documentation build configuration.
#
# Built on Read the Docs from this file directly (see ../.readthedocs.yaml) —
# unlike Scala projects there is no snippet-compilation step, so the Markdown
# sources in this directory are the build inputs as-is.

import os

# Canonical URL when served from Read the Docs (or a custom domain later).
# https://about.readthedocs.com/blog/2024/07/addons-by-default/
html_baseurl = os.environ.get(
    "READTHEDOCS_CANONICAL_URL",
    "https://sandcat.virtuslab.com/",
)

# Tell Jinja2 templates the build is running on Read the Docs.
if os.environ.get("READTHEDOCS", "") == "True":
    if "html_context" not in globals():
        html_context = {}
    html_context["READTHEDOCS"] = True

# -- General configuration ------------------------------------------------

extensions = [
    "myst_parser",
    "sphinx_rtd_theme",
    "sphinxcontrib.mermaid",
    "sphinx_llms_txt",
]

myst_enable_extensions = ["attrs_block"]
# Let the ```mermaid fenced blocks used throughout the existing docs render
# as diagrams without rewriting them into {mermaid} directives.
myst_fence_as_directive = ["mermaid"]
myst_heading_anchors = 3

# llms.txt export — documentation for an AI-agent sandbox should itself be
# consumable by AI agents.
llms_txt_title = "sandcat"
llms_txt_summary = (
    "Docker & dev container setup for securely running AI agents: "
    "sandboxed environment, transparent mitmproxy over WireGuard with an "
    "allow/deny network policy, and proxy-level secret substitution."
)
llms_txt_full_file = True

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

master_doc = "index"

project = "sandcat"
copyright = "2026, VirtusLab"
author = "VirtusLab"

# sandcat is CLI-versioned by date (see cli/.version at build time); the docs
# track master, so a branch label is more honest than a fake semver.
version = "latest"
release = "latest"

language = "en"

exclude_patterns = [
    "_build",
    "Thumbs.db",
    ".DS_Store",
    ".venv",
    "venv",
    "env",
    "**/site-packages/**",
    "**/node_modules/**",
    "_templates",
    "requirements.txt",
    "README.md",
]

pygments_style = "default"

# -- Options for HTML output ----------------------------------------------

html_theme = "sphinx_rtd_theme"
htmlhelp_basename = "sandcatdoc"

highlight_language = "bash"

# Edit-on-GitHub links in the page header.
html_context = {
    "display_github": True,
    "github_user": "VirtusLab",
    "github_repo": "sandcat",
    "github_version": "master",
    "conf_py_path": "/docs/",
}
