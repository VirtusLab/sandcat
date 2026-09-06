#!/bin/bash

sandcat_home="${SANDCAT_HOME:-/home/vscode}"
if [ -L "$sandcat_home/.local/share/sandcat/java-home" ]; then
    export JAVA_HOME="$sandcat_home/.local/share/sandcat/java-home"
fi
if [ -f "$sandcat_home/.local/share/sandcat/cacerts" ]; then
    export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$sandcat_home/.local/share/sandcat/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
fi
unset sandcat_home
