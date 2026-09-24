# OpenRouter Models Monitor

This repository contains a small Bash-based monitor for new models listed on [OpenRouter](https://openrouter.ai/models). It periodically checks the OpenRouter models API and sends a notification to Slack, Telegram, or both when it finds new models.

## Files

- [`monitor_openrouter_models.sh`](monitor_openrouter_models.sh)
  - Fetches models from `https://openrouter.ai/api/v1/models`.
  - Maintains a local state file: `.openrouter_models_last.json`.
  - Uses environment-based configuration loaded from [`.env`](.env) (see `.env.example`).
  - On each run:
    - Compares current model IDs with the previous run.
    - If new models exist:
      - Resolves display name and slug.
      - Sends a message to each channel that has a configuration:
        - Slack (via Incoming Webhook).
        - Telegram (via the Telegram Bot API).
      - The message lists:
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
    - `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` for Telegram notifications.

## Requirements

- `bash`
- `curl`
- `jq`
- `comm` (typically part of coreutils)

## Setup

1. Create your environment file:
   - `cp .env.example .env`
2. Edit [`.env`](.env). Set at least one notification channel:
   - For Slack, set `SLACK_WEBHOOK_URL` to your Slack Incoming Webhook URL.
   - For Telegram, set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`. See [Telegram setup](#telegram-setup).
   - To turn off a channel, leave its value empty.
3. Make the script executable:
   - `chmod +x ./monitor_openrouter_models.sh`
4. Run once manually to initialize the baseline:
   - `./monitor_openrouter_models.sh`
5. Add a cron job (example: every 15 minutes):
   - `*/15 * * * * /usr/bin/env bash /absolute/path/to/monitor_openrouter_models.sh >> /var/log/openrouter_models_monitor.log 2>&1`

## Telegram setup

1. Open a chat with `@BotFather` in Telegram.
2. Send `/newbot` and follow the instructions.
3. Copy the bot token that `@BotFather` gives you into `TELEGRAM_BOT_TOKEN`.
4. Send a message to your new bot. For a group, add the bot to the group and send a message in the group.
5. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser. Replace `<TOKEN>` with your bot token.
6. Copy the `chat.id` value into `TELEGRAM_CHAT_ID`. A group chat ID starts with `-`.

Telegram accepts a maximum of 4096 characters in one message. If the list of new models is longer, the script sends more than one message.
