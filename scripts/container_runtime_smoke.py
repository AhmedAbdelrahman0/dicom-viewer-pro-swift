#!/usr/bin/env python3
"""Preflight the local container runtime used by Tracer worker containers."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


SKIP = 77


def log(message: str) -> None:
    print(message, flush=True)


def find_runtime() -> str | None:
    override = os.environ.get("TRACER_CONTAINER_RUNTIME", "").strip()
    if override:
        return override
    for name in ("docker", "podman"):
        path = shutil.which(name)
        if path:
            return path
    return None


def run_command(command: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )


def configure_podman_environment(env: dict[str, str]) -> None:
    if os.environ.get("XDG_CONFIG_HOME"):
        return
    config = Path.home() / ".config"
    if not config.exists():
        return
    try:
        owner_uid = config.stat().st_uid
    except OSError as exc:
        raise RuntimeError(f"could not stat {config}: {exc}") from exc
    if owner_uid != os.getuid():
        fallback = Path.home() / ".tracer-podman-config"
        fallback.mkdir(parents=True, exist_ok=True)
        env["XDG_CONFIG_HOME"] = str(fallback)
        log(f"CONTAINER_RUNTIME_SMOKE_PODMAN_CONFIG {fallback}")


def configure_docker_environment(env: dict[str, str]) -> None:
    if not env.get("DOCKER_CONFIG"):
        docker_config = Path.home() / ".docker"
        if docker_config.exists():
            try:
                owner_uid = docker_config.stat().st_uid
            except OSError as exc:
                raise RuntimeError(f"could not stat {docker_config}: {exc}") from exc
            if owner_uid != os.getuid():
                fallback = Path.home() / ".tracer-docker-config"
                fallback.mkdir(parents=True, exist_ok=True)
                env["DOCKER_CONFIG"] = str(fallback)
                log(f"CONTAINER_RUNTIME_SMOKE_DOCKER_CONFIG {fallback}")

    if not env.get("DOCKER_HOST"):
        for socket in (
            Path.home() / ".colima" / "default" / "docker.sock",
            Path.home() / ".colima" / "docker.sock",
        ):
            if socket.exists():
                env["DOCKER_HOST"] = f"unix://{socket}"
                log(f"CONTAINER_RUNTIME_SMOKE_DOCKER_HOST {env['DOCKER_HOST']}")
                break


def main() -> int:
    runtime = find_runtime()
    if not runtime:
        log("CONTAINER_RUNTIME_SMOKE_SKIPPED no docker or podman command found")
        return SKIP

    env = os.environ.copy()
    runtime_name = Path(runtime).name
    if runtime_name == "podman":
        try:
            configure_podman_environment(env)
        except RuntimeError as exc:
            log(f"CONTAINER_RUNTIME_SMOKE_FAILED podman config: {exc}")
            return 1
    elif runtime_name == "docker":
        try:
            configure_docker_environment(env)
        except RuntimeError as exc:
            log(f"CONTAINER_RUNTIME_SMOKE_FAILED docker config: {exc}")
            return 1

    log(f"CONTAINER_RUNTIME_SMOKE_RUNTIME {runtime}")
    try:
        result = run_command([runtime, "version"], env)
    except subprocess.TimeoutExpired:
        log("CONTAINER_RUNTIME_SMOKE_FAILED runtime version timed out")
        return 1
    except OSError as exc:
        log(f"CONTAINER_RUNTIME_SMOKE_FAILED could not launch runtime: {exc}")
        return 1

    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    if result.returncode != 0:
        detail = stderr or stdout or f"exit {result.returncode}"
        log(f"CONTAINER_RUNTIME_SMOKE_FAILED runtime is not healthy: {detail}")
        return 1

    first_line = (stdout or stderr).splitlines()[0] if (stdout or stderr) else "version ok"
    log(f"CONTAINER_RUNTIME_SMOKE_VERSION_OK {first_line}")

    image = os.environ.get("TRACER_CONTAINER_SMOKE_IMAGE", "docker.io/library/alpine:3.20")
    try:
        run_result = run_command([runtime, "run", "--rm", image, "true"], env)
    except subprocess.TimeoutExpired:
        log("CONTAINER_RUNTIME_SMOKE_FAILED container run timed out")
        return 1
    except OSError as exc:
        log(f"CONTAINER_RUNTIME_SMOKE_FAILED could not run container: {exc}")
        return 1
    if run_result.returncode != 0:
        detail = run_result.stderr.strip() or run_result.stdout.strip() or f"exit {run_result.returncode}"
        log(f"CONTAINER_RUNTIME_SMOKE_FAILED container run failed: {detail}")
        return 1

    log(f"CONTAINER_RUNTIME_SMOKE_OK image={image}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
