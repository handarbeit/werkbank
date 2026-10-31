# Credentials: a GitHub App

Runners need a credential to register with GitHub, and the overflow controller needs one to read
the queue and change runner labels. Use a **GitHub App** for both, not a personal access token
(PAT).

## Why not a personal token

- **Quota.** A person's tokens share one budget of 5,000 REST calls an hour, across every tool
  they use. An ephemeral runner asks for a registration token after *every job*, and the
  controller reads the queue every few seconds. On a busy org that's enough to exhaust the
  budget, and then the controller goes blind, runners can't re-register, and the person's own
  `gh` calls fail. An App installed on an org has its own budget (5,000 an hour, rising with the
  number of repos and users), which nobody else spends.
- **Ownership.** An App belongs to the org, not to whoever happened to set up CI. It survives
  that person leaving, and its permissions are exactly the two it needs.
- **Lifetime.** The App's private key never leaves your host; what reaches GitHub is a token
  that expires within an hour.

## 1. Create the App

In the org: **Settings → Developer settings → GitHub Apps → New GitHub App**, or go to
`https://github.com/organizations/<org>/settings/apps/new`.

| Setting | Value |
|---|---|
| GitHub App name | anything unique, e.g. `<org>-werkbank` |
| Homepage URL | your deployment repo, or `https://github.com/handarbeit/werkbank` |
| Callback URL, Setup URL | leave empty |
| Webhook | untick **Active** |
| Organization permissions → **Self-hosted runners** | **Read and write** (register runners, change labels) |
| Repository permissions → **Actions** | **Read-only** (the controller reads queued jobs; skip it if you don't run the controller) |
| Everything else | No access (Metadata: Read-only is added automatically) |
| Where can this GitHub App be installed? | **Only on this account** |

Then, on the App's page:

1. Note the **App ID** at the top of the General tab. It isn't secret.
2. **Install App** (left-hand menu) → **Install** on the org. Choose **All repositories**, or
   at least the repos the controller watches.
3. **Private keys** (near the bottom of the General tab) → **Generate a private key**. A
   `.pem` file downloads. On a phone the section can be hidden; switch the browser to its
   desktop site.

## 2. Put the key in `.env`

The key goes into your deployment's `.env` (mode 600, never committed) on one line, with its
newlines written as `\n`, in double quotes:

```bash
printf 'MY_APP_KEY="%s"\n' "$(awk '{printf "%s\\n", $0}' ~/Downloads/<app>.*.private-key.pem)" >> .env
chmod 600 .env
openssl rsa -in ~/Downloads/<app>.*.private-key.pem -check -noout   # "RSA key ok"
```

Then delete the downloaded `.pem`. If it lost the race with a cloud sync (an iCloud Drive file
that is still a placeholder reads as empty), check the line before you delete the file:
`grep -c 'BEGIN RSA PRIVATE KEY' .env` should print 1.

## 3. Runners

The runner image signs in as the App when `APP_ID`, `APP_PRIVATE_KEY` and `APP_LOGIN` are set,
instead of `ACCESS_TOKEN`:

```yaml
x-org: &org
  RUNNER_SCOPE: org
  ORG_NAME: my-org
  APP_ID: "123456"                 # not secret
  APP_PRIVATE_KEY: ${MY_APP_KEY}   # from .env
  APP_LOGIN: my-org                # the account the App is installed on
```

Name each credential per service, as above. **Don't give the services `env_file: .env`**: that
puts every variable in `.env` into every container, and the image clears only its own variables
(`ACCESS_TOKEN`, `APP_*`) before a job starts, so any job step, or any dependency's install
script, could read the rest.

Recreate the runners with `werkbank/bin/roll.sh` and check one:

```bash
docker compose logs <service> | grep -E "Obtaining access token|Runner successfully added|ERROR"
```

## 4. The overflow controller

In `overflow.json`, replace `token_var` with:

```json
"app_id": 123456,
"app_key_var": "MY_APP_KEY",
```

The controller signs a JWT with the key (through `openssl`, the key passed on a pipe), finds the
App's installation on `org`, and renews its installation token every hour. Check it once:

```bash
python3 werkbank/controller/overflow.py --config overflow.json --once --dry-run
```

## 5. Native macOS runners

`macos/setup.sh` registers each runner once, and accepts an App per owner in the conf file:

```bash
APPS=(my-org=123456:MY_APP_KEY)   # owner=app_id:variable holding the key in .env
```

A target whose owner has no `APPS` entry still uses `TOKEN_VARS`/`ACCESS_TOKEN`. For a
repo-level target the App needs **Repository → Administration: Read and write** on that repo,
because that's what repo-level registration requires.

## Repos outside the org

An App that can be installed "only on this account" can't be installed on a personal account or
another org. A repo-level runner for a repo there needs its own App created under that account,
or a fine-grained PAT with repository permission "Administration: Read and write" on that repo
(`ACCESS_TOKEN`, as before). Such runners are usually few, so the PAT's quota cost is small.

## Retire the old token

Once runners and controller run on the App, revoke the PAT they used (GitHub → Settings →
Developer settings → Personal access tokens), and remove it from `.env`.

## What jobs should use

Nothing here is for jobs. A workflow step that calls the API uses the job's own `GITHUB_TOKEN`
(`env: GH_TOKEN: ${{ github.token }}` for `gh`), limited by the workflow's `permissions:`, scoped
to its repo and expiring with the job. A job that needs another repo should use a separate,
narrowly scoped App through `actions/create-github-app-token`, never the runners' App: whoever
holds that key can register runners in your org and pick up its jobs.
