# Setup develop enviroment

## Init repo
```
./setup_ws.sh
```

## Run develop docker with pull exit image
```
./run_dev_with_pull.sh
```

This also ensures the standalone Zephyr Data Agent is running from
`~/zephyr-data-platform-agent-dev/deploy`. Set
`ZEPHYR_DATA_AGENT_DEPLOY_DIR` to use another deployment directory. Agent
startup failures are warnings by default so data collection cannot block the
robot container; set `ZEPHYR_DATA_AGENT_REQUIRED=1` to make them fatal.

Codex IDE/CLI history is persisted on the host in `.codex-container` next to
this workspace. Set `CODEX_STATE_DIR` before launching to use another host
directory.

## (Optional) Run develop docker with build image from Dockerfile

```
./run_dev_with_build.sh
```
