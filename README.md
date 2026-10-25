# Shipyard GitHub Action

Sends your plugin builds to a Pterodactyl panel running the Shipyard extension. Each file is stamped with where it came from, signed with your repository's Shipyard secret, and uploaded. The panel then offers it on the **Deploy** tab of the servers you chose.

## Setup

1. On the panel: **Admin → Extensions → Shipyard**, add a project for the repository and **Generate secret**. You get two values: a CI secret and a webhook secret.
2. In the repository: add the **CI secret** as an Actions secret named `SHIPYARD_SECRET`.
3. In the repository: add a webhook to the URL the admin page shows, content type `application/json`, the **webhook secret** (not the CI one: a build is only deployable once GitHub confirms the run, and whoever can read CI secrets must not be able to fake that), events **Workflow runs** and **Workflow jobs**. The panel only lets a build be deployed once GitHub itself confirms the run.
4. Add the step after your build:

```yaml
- uses: RedStoner/shipyard-action@v1
  with:
    panel-url: https://panel.example.com
    files: build/libs/*-all.jar
  env:
    SHIPYARD_SECRET: ${{ secrets.SHIPYARD_SECRET }}
```

On GitHub Free, organisation secrets do not reach private repositories: add the secret to each repository.

Run the step in the workflow that builds the files (in the build job, or a later job of the same workflow). The panel checks each upload against GitHub's webhooks for the run that sent it, so:
- a workflow started by `workflow_run` is refused: it is a different run from the build, on the default branch;
- files are refused once GitHub has reported their run finished more than 10 minutes earlier, so re-running only this step much later does not work; re-run the workflow.

## Inputs

| Input | Default | |
|---|---|---|
| `panel-url` | (required unless `upload: false`) | Base URL of the panel. Must be `https://`. |
| `files` | (required) | Globs of `.jar`/`.zip` files, separated by spaces or new lines. Paths with spaces are not supported. |
| `version` | from the file name | Version written into the build stamp. |
| `stamp` | `true` | Write `META-INF/shipyard-build.json` into each archive (into a copy; your build output is not changed). |
| `upload` | `true` | `false` stamps the files **in place** and sends nothing: for workflows that keep another handover or only keep the build as an Actions artifact. No panel URL or secret needed. |
| `max-mb` | `95` | Refuse larger files. Keep it under your proxy's limit (Cloudflare: 100 MB). |
| `retries` | `3` | Retries on network errors, 429 and 5xx, with backoff. |

## What it checks before sending anything

- File names use only letters, digits, `. _ + -`, space and `' ! ( )`, at most 128 characters, and end in `.jar` or `.zip`. Bad names fail the step rather than being changed.
- No two files are the same plugin. A build that makes both a shadow jar and a plain jar fails with a message naming both; list only the one servers should run.
- The secret comes only from the `SHIPYARD_SECRET` environment variable and is never passed on a command line. The log shows its length and a fingerprint, which you can compare with the admin page.

## Requirements

A Linux or macOS runner with `sh`, `curl`, `zip` (or `python3`) and `python3` or `node` for signing. GitHub-hosted runners have all of them.

## Tests

`sh action/tests/run.sh`. Set `SHIPYARD_TEST_PANEL`, `SHIPYARD_TEST_SECRET` and `SHIPYARD_TEST_REPO` to also upload to a dev panel.
