# Alertmanager overlay

Optional per-deployment routes and receivers, for a deployment that wants its
own Slack channel on a shared stack. `bin/render-configs.sh` splices
`routes.yml` and `receivers.yml` from this directory into
`alertmanager.yml.template` at its `# @overlay-routes` / `# @overlay-receivers`
markers, then envsubsts the result with `.env`. Both files are gitignored here;
keep the master copies in the deployment's overlay repo. Write them unindented.

Overlay routes sit after the Watchdog route and the dev mute, before the
environment routes. Keep webhook URLs in `.env`, never in the fragments.

`routes.yml`:

```yaml
- matchers:
    - deployment="gambia"
    - environment="uat"
  receiver: slack-gambia-uat
  routes:
    - matchers:
        - severity="critical"
      receiver: slack-gambia-uat
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 4h
```

`receivers.yml` (`*slack_title` / `*slack_text` reuse the default message format):

```yaml
- name: slack-gambia-uat
  slack_configs:
    - api_url: "${SLACK_WEBHOOK_URL_GAMBIA_UAT}"
      channel: "${SLACK_CHANNEL_GAMBIA_UAT}"
      send_resolved: true
      title: *slack_title
      text: *slack_text
```

Apply: `bin/render-configs.sh`, then `curl -X POST localhost:9093/-/reload`.
Check with `amtool config routes test deployment=gambia environment=uat severity=critical`.
