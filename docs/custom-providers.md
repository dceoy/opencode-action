# Custom providers

Use this guide for model providers that are not built into OpenCode, typically ones exposing an OpenAI-compatible API. Sakura AI Engine is the exception: it ships pre-configured in this action's bundled toolkit (see below), so most users need no `opencode.json` at all.

## Configure the provider

Add `opencode.json` to the repository root for normal mention-driven runs:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "myprovider": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "My Provider",
      "options": {
        "baseURL": "https://api.example.com/v1",
        "apiKey": "{env:MYPROVIDER_API_KEY}"
      },
      "models": {
        "my-model": {
          "name": "My Model"
        }
      }
    }
  }
}
```

Replace the placeholders as follows:

- `myprovider`: a unique provider ID. The same value is used as the prefix of the action's `model` input.
- `npm`: use `@ai-sdk/openai-compatible` for APIs implementing `/v1/chat/completions`. Use `@ai-sdk/openai` instead when the provider requires `/v1/responses`.
- `options.baseURL`: the provider's API base URL.
- `options.apiKey`: an environment-variable reference for the provider credential.
- `models`: the exact model IDs accepted by the provider. Add one entry for each model that the workflow may select.

OpenCode replaces an unset `{env:VARIABLE}` reference with an empty string, so ensure the corresponding workflow secret is configured.

## Configure the workflow

Create the provider API key as a GitHub Actions secret, expose it to the action step, and select the model using `provider/model` format:

```yaml
env:
  MYPROVIDER_API_KEY: ${{ secrets.MYPROVIDER_API_KEY }}
with:
  model: myprovider/my-model
```

For local interactive use, OpenCode can store a custom provider credential through `/connect`. GitHub Actions should use an environment variable backed by an Actions secret instead of an interactive login.

## Sakura AI Engine example

Sakura AI Engine is already pre-configured as the `sakura` provider in the bundled toolkit's `.opencode/opencode.jsonc`, so `model: sakura/gpt-oss-120b` and the other bundled model IDs work out of the box whenever `use-bundled-toolkit: true` (the default) and `SAKURA_AI_ENGINE_API_KEY` is set — no repository `opencode.json` is required. The configuration below is only needed to run with `use-bundled-toolkit: false`, or to add Sakura model IDs beyond the bundled set.

Sakura AI Engine exposes an OpenAI-compatible `/v1/chat/completions` endpoint. A minimal configuration is:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "sakura": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Sakura AI Engine",
      "options": {
        "baseURL": "https://api.ai.sakura.ad.jp/v1",
        "apiKey": "{env:SAKURA_AI_ENGINE_API_KEY}",
        "timeout": 900000,
        "chunkTimeout": 900000
      },
      "models": {
        "gpt-oss-120b": {
          "name": "gpt-oss-120b"
        }
      }
    }
  }
}
```

Configure the workflow step with:

```yaml
env:
  SAKURA_AI_ENGINE_API_KEY: ${{ secrets.SAKURA_AI_ENGINE_API_KEY }}
with:
  model: sakura/gpt-oss-120b
```

Replace or extend `models` with model IDs available to the Sakura AI Engine account.

Leave the action's `variant` input empty for Sakura models. Sakura AI Engine documents no OpenCode model variants, so each bundled model declares an empty `variants` object in `.opencode/opencode.jsonc` and the action rejects a nonempty `variant` before the run starts:

```yaml
with:
  model: sakura/preview/Kimi-K2.7-Code
  # variant: thinking  # rejected: this model declares no variants
```

## Variants for custom providers

`variant` validation only applies while the bundled `.opencode/opencode.jsonc` registry is authoritative for the selected model, and only for models actually declared in it. It is not validated whenever:

- the model is absent from that registry entirely — a custom `opencode.json` provider, a built-in OpenCode provider such as `anthropic` or `openai`, or a model discovered dynamically by its provider (never listed in `opencode.json`, such as an OpenCode Go model). `variant` passes through **silently**, since the model's absence says nothing about compatibility;
- the model is declared in the registry but without a `variants` key. `variant` passes through with a **warning** that compatibility was not validated;
- `use-bundled-toolkit: false` is set, so the bundled registry is never installed. `variant` passes through with a warning;
- a workflow `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, or `OPENCODE_CONFIG_CONTENT` override is present, or a repository `opencode.json`/`opencode.jsonc` or `.opencode/opencode.json`/`opencode.jsonc` redefines the same provider/model (OpenCode 1.2.14+ loads the latter after the former). `variant` passes through with a warning;
- a nonempty `plugin` array is declared in `OPENCODE_CONFIG_CONTENT` or a repository `opencode.json(c)`/`.opencode/opencode.json(c)`, or a project or global `.opencode/plugins` directory is not empty — OpenCode auto-loads plugins from that directory regardless of config. A plugin's `config` hook can mutate provider/model metadata before OpenCode validates it, so `variant` passes through with a warning;
- a workflow-set `XDG_CONFIG_HOME` points OpenCode's global config search outside `~/.config/opencode`, the one directory the action installs its bundled registry into. `variant` passes through with a warning;
- a `~/.config/opencode/opencode.json` or `opencode.jsonc` already existed on the runner before this run (the action only installs its bundled file when the destination is empty, so a reused self-hosted runner can keep an older or externally managed config). `variant` passes through with a warning;
- OpenCode's managed config directory (`/etc/opencode` by default) contains an `opencode.json` or `opencode.jsonc` that redefines the same provider/model or declares a plugin. OpenCode loads this directory last, with the highest precedence of any config source — above even `OPENCODE_CONFIG_CONTENT` — and this action never clears or replaces it, so this check applies even on review-only runs, which otherwise treat the bundled registry as authoritative. `variant` passes through with a warning.

A passed-through `variant` that the provider rejects surfaces as a provider error rather than a configuration error. If a run with a variant fails in an unclear way, retry with an empty `variant` to confirm whether the variant is the cause.

## Limitations and security

The bundled `/review-pr` mode installs a fresh trusted OpenCode configuration and disables project and caller-supplied configuration. Custom providers defined in the repository's `opencode.json` are therefore unavailable to `/review-pr`; use a built-in provider for isolated review runs. Providers defined in the bundled toolkit's own `.opencode/opencode.jsonc` are a separate case: that file is reinstalled fresh for every `/review-pr` run, so `sakura/*` models stay selectable there too, provided the workflow step still exposes `SAKURA_AI_ENGINE_API_KEY`.

Treat project provider configuration as trusted input before exposing a provider secret. The configuration controls `baseURL` and optional request headers, so an untrusted change could redirect the credential to another endpoint. Restrict workflow triggers and secret access accordingly.

## References

- [OpenCode custom provider documentation](https://opencode.ai/docs/providers/#custom-provider)
- [OpenCode configuration variables](https://opencode.ai/docs/config/#variables)
- [Sakura AI Engine OpenCode guide](https://ai.sakura.ad.jp/column/ai-engine-client-guide-opencode/)
