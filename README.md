# Setup develop enviroment

## Init repo
```
./setup_ws.sh
```

## Run develop docker with pull exit image
```
./run_dev_with_pull.sh
```

Codex IDE/CLI history is persisted on the host in `.codex-container` next to
this workspace. Set `CODEX_STATE_DIR` before launching to use another host
directory.

## (Optional) Run develop docker with build image from Dockerfile

```
./run_dev_with_build.sh
```
