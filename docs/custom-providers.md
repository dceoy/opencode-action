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
        "timeout": 900000
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

## Limitations and security

The bundled `/review-pr` mode installs a fresh trusted OpenCode configuration and disables project and caller-supplied configuration. Custom providers defined in the repository's `opencode.json` are therefore unavailable to `/review-pr`; use a built-in provider for isolated review runs. Providers defined in the bundled toolkit's own `.opencode/opencode.jsonc` are a separate case: that file is reinstalled fresh for every `/review-pr` run, so `sakura/*` models stay selectable there too, provided the workflow step still exposes `SAKURA_AI_ENGINE_API_KEY`.

Treat project provider configuration as trusted input before exposing a provider secret. The configuration controls `baseURL` and optional request headers, so an untrusted change could redirect the credential to another endpoint. Restrict workflow triggers and secret access accordingly.

## References

- [OpenCode custom provider documentation](https://opencode.ai/docs/providers/#custom-provider)
- [OpenCode configuration variables](https://opencode.ai/docs/config/#variables)
- [Sakura AI Engine OpenCode guide](https://ai.sakura.ad.jp/column/ai-engine-client-guide-opencode/)
