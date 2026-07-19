# NixClaw is a pure-Python client. Keep its source, Nix-pinned CLI dependencies,
# and launcher root-owned.
COPY nixclaw/src/ /opt/nixclaw/src/
COPY nixclaw/vendor/ /opt/nixclaw/vendor/
COPY nixclaw/nixclaw-agent /usr/local/bin/nixclaw-agent
RUN chown -R root:root /opt/nixclaw /usr/local/bin/nixclaw-agent \
    && find /opt/nixclaw -type d -exec chmod 0555 {} + \
    && find /opt/nixclaw -type f -exec chmod 0444 {} + \
    && chmod 0555 /usr/local/bin/nixclaw-agent \
    && PYTHONPATH=/opt/nixclaw/src:/opt/nixclaw/vendor \
      /opt/hermes/.venv/bin/python -c \
      "import httpx, pydantic, typer; import nixclaw.cli"
