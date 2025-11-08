# OpenRouter Models Monitor

This repository contains a small Bash-based monitor for new models listed on [OpenRouter](https://openrouter.ai/models). It periodically checks the OpenRouter models API and sends a Slack notification whenever new models are detected.

## Files

- [`monitor_openrouter_models.sh`](monitor_openrouter_models.sh)
  - Fetches models from `https://openrouter.ai/api/v1/models`.
  - Maintains a local state file: `.openrouter_models_last.json`.
  - Uses environment-based configuration loaded from [`.env`](.env) (see `.env.example`).
  - On each run:
    - Compares current model IDs with the previous run.
    - If new models exist:
      - Resolves display name and slug.
      - Sends a Slack message (via Incoming Webhook) listing:
        - Model name
        - Model ID
        - Direct link: `https://openrouter.ai/models/{slug}`
    - First run only initializes baseline (no notification).

- [`.gitignore`](.gitignore)
  - Ignores:
    - `.openrouter_models_last.json` (local state)
    - `.env` (local secrets/config)

- [`.env.example`](.env.example)
  - Example configuration file.
  - Shows how to set:
    - `SLACK_WEBHOOK_URL` for Slack notifications.

## Requirements

- `bash`
- `curl`
- `jq`
- `comm` (typically part of coreutils)

## Setup

1. Create your environment file:
   - `cp .env.example .env`
2. Edit [`.env`](.env):
   - Set `SLACK_WEBHOOK_URL` to your real Slack Incoming Webhook URL.
3. Make the script executable:
   - `chmod +x ./monitor_openrouter_models.sh`
4. Run once manually to initialize the baseline:
   - `./monitor_openrouter_models.sh`
5. Add a cron job (example: every 15 minutes):
   - `*/15 * * * * /usr/bin/env bash /absolute/path/to/monitor_openrouter_models.sh >> /var/log/openrouter_models_monitor.log 2>&1`