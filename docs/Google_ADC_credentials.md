# Google Application Default Credentials (ADC) Setup for Iris

This guide details how to configure and use **Application Default Credentials (ADC)** with Google's Gemini models in Iris.

---

## Overview

Iris supports both standard Gemini API Keys and Google Cloud **Application Default Credentials (ADC)**. ADC allows you to authenticate using your local `gcloud` developer identity or GCP service account credentials without hardcoding API keys.

Because Iris calls Google's REST APIs directly via native HTTP requests, specific OAuth scopes and quota project headers are required depending on whether you are hitting **Google AI Studio** (`generativelanguage.googleapis.com`) or **Vertex AI** (`aiplatform.googleapis.com`).

---

## Scope Requirements & Authentication Paths

### Endpoint Scope Summary
* **Google AI Studio API (`generativelanguage.googleapis.com`)**: Strictly requires `https://www.googleapis.com/auth/generative-language`.
* **Vertex AI API (`aiplatform.googleapis.com`)**: Requires `https://www.googleapis.com/auth/cloud-platform`.

---

## Step-by-Step Setup

### 1. Enable Required APIs in Google Cloud

Ensure the necessary APIs are enabled in your GCP project:

```bash
# Enable Generative Language API (for AI Studio)
gcloud services enable generativelanguage.googleapis.com

# Enable Vertex AI API (for Vertex AI)
gcloud services enable aiplatform.googleapis.com
```

---

### 2. Authenticate ADC

Choose the path that matches your target endpoint:

#### Path A: Google AI Studio (`generativelanguage.googleapis.com`) via ADC
`gcloud`'s built-in OAuth Client ID rejects `https://www.googleapis.com/auth/generative-language` with `Error 400: invalid_scope`. To authenticate for AI Studio via ADC, you must pass your own GCP OAuth Client Secrets file created in Google Cloud Console:

```bash
gcloud auth application-default login \
  --client-id-file=client_secret.json \
  --scopes="https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/generative-language"
```

#### Path B: GCP Vertex AI (`aiplatform.googleapis.com`) via ADC — *(Vertex-Only)*
Vertex AI endpoints accept the standard `cloud-platform` scope.

```bash
gcloud auth application-default login --scopes="https://www.googleapis.com/auth/cloud-platform"
```

> ⚠️ **Important Caveat**: Path B is **Vertex AI ONLY**. It will **NOT** work with Iris's default out-of-the-box configuration (which hits Google AI Studio at `generativelanguage.googleapis.com` and will return `HTTP 403: ACCESS_TOKEN_SCOPE_INSUFFICIENT`). You **MUST** override **Gemini Base URL** in Iris Settings with your project's Vertex AI endpoint (`https://aiplatform.googleapis.com/...`) to use Path B.

---

### 3. Configure Your Quota & Billing Project

Set your default project (required for `x-goog-user-project` headers):

```bash
export GOOGLE_CLOUD_QUOTA_PROJECT="your-gcp-project-id"
# or
gcloud config set project your-gcp-project-id
```

---

### 4. Enable ADC in Iris Settings

1. Open **Iris Settings**.
2. Set **Primary Provider** to `Gemini`.
3. Under **Authentication Method**, select `Application Default Credentials (ADC)`.
4. For AI Studio, leave **Gemini Base URL** blank. For Vertex AI, set your custom Vertex endpoint.

---

## Claude on Vertex AI (Anthropic provider)

The same ADC login also serves **Anthropic → Authentication Method → Vertex AI (ADC)**, which
calls Claude models hosted in a Google Cloud project through Vertex AI (#181). Differences from
the Gemini ADC path:

* **The project is a setting, not the quota project.** Enter the project whose Vertex AI serves
  Claude in *Vertex AI Project*. Settings prefills it from your ADC quota project when the field
  is empty, but never substitutes it silently: the project that holds your quota and the project
  that hosts Claude are routinely different. That project is also sent as `x-goog-user-project`.
* **Location.** `global` (the default, and the only location that serves current-generation
  models such as `claude-sonnet-5` and `claude-fable-5`), `us` or `eu` for a multi-region
  endpoint, or a region such as `us-east5` for Sonnet 4.6 and earlier.
* **Model ids.** The tier fields take Anthropic's ids. Vertex spells a dated id with `@`, so
  `claude-haiku-4-5-20251001` is sent as `claude-haiku-4-5@20251001`; bare ids pass through.
  *List Available Models…* sends one one-token request per Claude id Iris knows about, at the
  configured location, and shows the ones your project can call there (a few dozen tokens in
  total); a model released later can still be typed into a tier field. A model the project cannot
  call (not enabled in Model Garden, or one whose publisher terms such as data sharing the project
  has not accepted, which Vertex reports as a 403) is left out; a mistake that fails every model,
  such as the wrong project or a missing scope, is reported as an error, not as an empty list.
* **Enablement.** A model must be enabled for the project in Model Garden before Vertex will
  serve it; until then the request fails with a 404 naming the publisher model.
* **Scope.** Vertex needs `https://www.googleapis.com/auth/cloud-platform`, the same scope the
  Gemini Vertex path uses, so one `gcloud auth application-default login` covers both.

## Troubleshooting

| Error | Cause | Solution |
| :--- | :--- | :--- |
| `Error 400: invalid_scope` | `generative-language` scope requested with `gcloud` default client ID | Supply your own `--client-id-file=client_secret.json` when running `gcloud auth application-default login`. |
| `HTTP 403: ACCESS_TOKEN_SCOPE_INSUFFICIENT` | `cloud-platform` scope token used against AI Studio (`generativelanguage.googleapis.com`) | Re-authenticate using Path A (`--client-id-file` with `generative-language` scope) or switch to Vertex AI (`aiplatform.googleapis.com`). |
| `HTTP 401: ACCESS_TOKEN_TYPE_UNSUPPORTED` | `gcloud auth` user token used instead of ADC token | Run `gcloud auth application-default login` (do not rely on standard `gcloud auth login`). |
| `HTTP 403: Quota project missing / PERMISSION_DENIED` | No GCP project associated with ADC request | Set project via `gcloud config set project <PROJECT_ID>` or export `GOOGLE_CLOUD_QUOTA_PROJECT=<PROJECT_ID>`. |
