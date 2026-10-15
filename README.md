# mv-dev-bootstrap

First step of setting up a Mutual Vision developer machine (macOS or Linux).

```bash
curl -fsSL https://raw.githubusercontent.com/yolkstudio/mv-dev-bootstrap/main/bootstrap.sh | bash
```

Prefer to read it first (recommended):

```bash
curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/yolkstudio/mv-dev-bootstrap/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## What it does

1. **Base packages** – build tools on Linux (`apt` or `dnf`); on macOS Homebrew installs the Xcode Command Line Tools.
2. **Homebrew** – installs it if missing and adds it to your shell profile.
3. **Core CLIs** – `git`, `azure-cli`.
4. **Git identity** – asks for your name and `@mutualvision.co.uk` email if not set.
5. **SSH key** – creates `~/.ssh/id_ed25519` if missing and pins it for `ssh.dev.azure.com`. Adding it to Azure DevOps (<https://dev.azure.com/Mutual-Vision/_usersSettings/keys>) is optional – only needed if you want SSH remotes.
6. **Azure** – `az login` with your MV account.
7. **Azure DevOps** – configures git to authenticate to `dev.azure.com` with your Azure sign-in (short-lived Entra tokens: no PAT, no SSH key upload), then waits until you have read access to the private tooling repo.
8. **Mv.Common.Tooling** – clones it to `~/repos/Mv.Common.Tooling` and runs its `install.sh`, which installs the MV-specific tooling (kubectl/AKS contexts, DB proxy, Claude Code plugins, …).

Everything is idempotent: re-run it any time to repair or update a machine.

### No access to Mv.Common.Tooling yet?

The script pauses and tells you. Ask your team lead for **Read** access to `Mv.Common.Tooling` in the **Singularity** project on Azure DevOps, then press Enter (or re-run the command later).

## Options

```
bash bootstrap.sh --help
  --non-interactive   never prompt (also NONINTERACTIVE=1)
```

| Variable | Default |
| --- | --- |
| `MV_TOOLING_REPO` | `https://dev.azure.com/Mutual-Vision/Singularity/_git/Mv.Common.Tooling` |
| `MV_TOOLING_DIR` | `~/repos/Mv.Common.Tooling` |
| `MV_TOOLING_REF` | `main` |
| `MV_TENANT_ID` | MV Entra tenant |

## Contributing

This repository is **public** and is piped straight into people's shells.

- No secrets, internal hostnames, IPs or customer data — those belong in `Mv.Common.Tooling`.
- Keep it small: install just enough to reach the private repo; everything else goes there.
- Every step must be safe to re-run.
- Changes go through a reviewed PR; CI runs `shellcheck` and a Linux smoke test.
