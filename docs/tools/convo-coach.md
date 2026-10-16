<convoCoach>
    <objective>
        TypeScript CLI that reads a transcription produced by `ntakker-cli` (single-channel or
        dual-channel JSONL sidecar) and asks a configurable LLM for live conversational
        coaching — phrased as "advise me on what I could ask, suggest, request, or answer
        right now." The LLM response is streamed token-by-token to stdout AND always also
        written to a sidecar file `<transcript-basename>.advice-<YYYYMMDD-HHMMSS>.md`
        placed next to the source transcript. All eight standard LLM providers (OpenAI,
        Anthropic, Google Gemini, Azure OpenAI, Azure AI Inference / Foundry, Ollama,
        LiteLLM, MLX-LM) are supported out of the box via LangChain (`@langchain/*`).
    </objective>
    <command>
        convo-coach [--transcript &lt;path&gt;] [--last &lt;duration&gt;] [--since &lt;timestamp&gt;]
                    [--provider &lt;name&gt;] [--model &lt;id&gt;] [--system-prompt &lt;path&gt;]
                    [--debounce &lt;duration&gt;] [--on-overflow &lt;truncate-start|truncate-end|error&gt;]
                    [--recordings-dir &lt;path&gt;]
    </command>
    <info>
        ## Overview

        `convo-coach` sits beside the `ntakker-cli` recording pipeline and gives the user
        in-the-moment guidance based on the live or post-session transcript.  It reads
        the conversation window you specify, builds a single-shot LLM prompt from your
        configurable coaching system message and the transcript text, streams the response
        to `stdout` while simultaneously appending every token to a durable `.advice-*.md`
        sidecar, then prints a metrics block (provider, model, token usage, latency).

        The tool lives under `tools/convo-coach/` inside the project repository as a
        Node/TypeScript workspace package following the same layout as `dual-transcript-merger`.

        ---

        ## Input modes

        The tool resolves its transcript input through the following priority chain
        (first winning source wins):

        1. **`--transcript <path>`** — explicit path to a `.jsonl` sidecar or plain `.txt`
           transcript produced by `ntakker-cli`.
        2. **Piped stdin** — when data is piped in (no controlling TTY), the tool reads
           from stdin. A coaching request fires after the TTY sends Enter, or automatically
           after the debounce window (see `COACH_DEBOUNCE`) when no TTY is present.
        3. **Auto-detect** — when neither `--transcript` nor piped input is present, the
           tool scans `NTAKKER_RECORDINGS_DIR` (default `~/Recordings`) for the most-recently
           modified `ntakker-cli` sidecar and uses it.

        ### Channels and speakers

        ntakker sidecars carry `source` (`mic`, `system` or `mixed`) and, with
        diarization, `speaker`. `mic` lines are tagged `[A]` (the user) and `system`
        lines `[B]` (the remote side); `mixed` lines carry no channel tag. A speaker
        label is shown after the channel, e.g. `[B] [Speaker 2] (en): …`. An explicit
        `channel: "A" | "B"` field, when present, wins over `source`.

        ---

        ## Configuration

        Configuration is resolved in the following priority order (lowest → highest):

        1. Shell environment variables (`process.env`)
        2. `~/.tool-agents/convo-coach/.env`
        3. Local `.env` in the current working directory
        4. CLI flags (always win)

        Missing required configuration — such as a provider API key when a non-local
        provider is selected — raises an exception immediately. No fallback values are
        substituted.

        On startup the tool checks for `~/.tool-agents/convo-coach/` and creates the
        directory (mode `0700`) if it is absent, matching the project convention.

        ---

        ## Environment variables

        ### LLM provider keys (vendor-canonical names)

        #### Direct OpenAI
        | Variable         | Purpose |
        |------------------|---------|
        | `OPENAI_API_KEY` | API key for api.openai.com. Required when `--provider openai`. |
        | `OPENAI_BASE_URL`| Override the OpenAI base URL (e.g. for proxies). Optional. |
        | `OPENAI_ORG_ID`  | OpenAI organisation ID. Optional. |

        #### Direct Anthropic
        | Variable              | Purpose |
        |-----------------------|---------|
        | `ANTHROPIC_API_KEY`   | API key for api.anthropic.com. Required when `--provider anthropic`. |
        | `ANTHROPIC_BASE_URL`  | Override the Anthropic base URL. Optional. |

        #### Google Gemini
        | Variable        | Purpose |
        |-----------------|---------|
        | `GOOGLE_API_KEY`| API key for the Google AI Gemini API. Required when `--provider google`. `GEMINI_API_KEY` is accepted as an alias. |

        #### Azure OpenAI
        | Variable                  | Purpose |
        |---------------------------|---------|
        | `AZURE_OPENAI_API_KEY`    | Azure OpenAI resource key. Required when `--provider azure-openai`. |
        | `AZURE_OPENAI_ENDPOINT`   | Full endpoint URL, e.g. `https://<resource>.openai.azure.com`. Required. |
        | `AZURE_OPENAI_DEPLOYMENT` | Deployment name. Required (passed as model identifier to the SDK). |
        | `AZURE_OPENAI_API_VERSION`| Optional. **Leave unset** for new deployments — the SDK then uses its `v1` default which routes to Azure's GA endpoint `https://<resource>.openai.azure.com/openai/v1/...` (no dated api-version required, supports current models such as `gpt-5.x`). Set to a dated preview version like `2025-04-01-preview` only if you need the legacy deployment-based URL pattern for older deployments. |

        Note: `convo-coach` reads `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_ENDPOINT` from its
        own four-tier chain and passes them explicitly to LangChain. With
        `AZURE_OPENAI_API_VERSION` unset it uses `ChatOpenAI` against `<endpoint>/openai/v1`;
        with it set it uses `AzureChatOpenAI`, deriving the resource name by stripping the URL
        scheme and the `.openai.azure.com` suffix.

        Migration tip — if you previously had `AZURE_OPENAI_API_VERSION=2024-12-01-preview`
        (or any 2024-vintage value) exported in your shell and you hit `API version not
        supported` errors against current models, simply `unset AZURE_OPENAI_API_VERSION`
        and re-run. The SDK's `v1` default takes over and the GA endpoint accepts the
        request without a dated api-version.

        #### Azure AI Inference / Foundry
        | Variable                      | Purpose |
        |-------------------------------|---------|
        | `AZURE_AI_INFERENCE_KEY`      | API key for the Azure AI Foundry inference endpoint. Required when `--provider azure-ai-inference`. Also accepted as `ANTHROPIC_FOUNDRY_API_KEY` (alias). |
        | `AZURE_AI_INFERENCE_ENDPOINT` | Full endpoint URL for the Foundry model. Required. Also accepted as `ANTHROPIC_FOUNDRY_ENDPOINT` (alias). |

        Aliases are read only when the canonical name is unset. Document them as a
        compatibility convenience for shells that already export the non-canonical
        names — new setups should prefer the canonical `AZURE_AI_INFERENCE_*` names.

        #### Ollama (local)
        | Variable      | Purpose |
        |---------------|---------|
        | `OLLAMA_HOST` | Base URL of the local Ollama server (default `http://127.0.0.1:11434` when unset). Required when `--provider ollama` and the server is not on the default port. |

        #### LiteLLM proxy (local or remote)
        | Variable            | Purpose |
        |---------------------|---------|
        | `LITELLM_PROXY_URL` | Base URL of the LiteLLM proxy server. Required when `--provider litellm`. Also accepted as `LITELLM_API_BASE`. |
        | `LITELLM_MASTER_KEY`| Auth key for the LiteLLM proxy. Optional if the proxy runs unauthenticated. Also accepted as `LITELLM_API_KEY`. |

        #### MLX-LM (local)
        MLX-LM exposes an OpenAI-compatible server; `convo-coach` uses `OPENAI_BASE_URL`
        pointed at the MLX-LM server and treats the provider as `mlx`. No dedicated env var.
        Specify `--provider mlx --model <model-id>` where `<model-id>` matches what the
        MLX-LM server was started with.

        ---

        ### Tool-specific configuration variables

        #### COACH_PROVIDER
        Default LLM provider when `--provider` is not passed on the CLI.
        Accepted values: `openai` | `anthropic` | `google` | `azure-openai` |
        `azure-ai-inference` | `ollama` | `litellm` | `mlx`.
        If unset AND `--provider` is not supplied, the tool defaults to `azure-openai`
        per the documented exception in the project's CLAUDE.md (Project Memory
        Exception 003). The Azure OpenAI credentials (`AZURE_OPENAI_API_KEY`,
        `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`)
        must still be present — only the *provider selection* falls back, not the
        credentials.

        #### COACH_MODEL
        Default model ID when `--model` is not passed on the CLI.
        Per-provider recommended defaults (used only when COACH_MODEL is set to these
        values or when documenting typical usage):
        - `openai` → `gpt-4o-mini`
        - `anthropic` → `claude-haiku-4-5-20251001`
        - `google` → `gemini-2.5-flash`
        - `azure-openai` → value of `AZURE_OPENAI_DEPLOYMENT`
        - `ollama` → `llama3.1:8b`
        - `azure-ai-inference`, `litellm`, `mlx` → no default; user must specify `--model`

        If `COACH_MODEL` is unset AND `--model` is not supplied AND no per-provider default
        applies, the tool raises a configuration error.

        #### NTAKKER_RECORDINGS_DIR
        Folder that auto-detect scans for the most-recently modified `ntakker-cli` sidecar
        transcript when no `--transcript` is given and no input is piped via stdin.
        Default `~/Recordings` when unset.
        Note: this is a `convo-coach`-owned variable; `ntakker-cli` itself does not read it.

        #### COACH_DEBOUNCE
        Default debounce duration for stdin streaming when no controlling TTY is available.
        A coaching request fires this long after the last segment arrives on stdin.
        Format: integer + unit suffix — `15s`, `2m`, `1h`.
        If unset, the tool defaults to `15s`.

        #### COACH_ON_OVERFLOW
        Default strategy when the windowed transcript exceeds the model's context window.
        Accepted values:
        - `truncate-start` (default when unset): drop oldest segments until the transcript fits.
        - `truncate-end`: drop newest segments (preserves conversation start).
        - `error`: raise an exception instead of truncating.

        #### COACH_SYSTEM_PROMPT_PATH
        Optional path to a markdown file whose contents replace the bundled default
        coaching system prompt verbatim as the LLM system message.
        CLI flag `--system-prompt <path>` takes precedence over this variable.
        If unset and `--system-prompt` is not given, the bundled default prompt is used.

        ---

        ## Command-line parameters

        | Parameter                                         | Required | Description |
        |---------------------------------------------------|----------|-------------|
        | `--transcript <path>`                             | No       | Path to a `ntakker-cli` JSONL sidecar or plain `.txt` transcript. When omitted, falls back to piped stdin then auto-detect. |
        | `--last <duration>`                               | No       | Slice the transcript to only the last N of conversation. Format: `30s`, `5m`, `1h`. When combined with `--since`, the later boundary (more recent) wins. |
        | `--since <timestamp>`                             | No       | Slice the transcript to only segments after this timestamp. Accepts ISO-8601, Unix epoch (seconds), or relative values such as `5m` (5 minutes ago). |
        | `--provider <name>`                               | No       | LLM provider to use. One of `openai`, `anthropic`, `google`, `azure-openai`, `azure-ai-inference`, `ollama`, `litellm`, `mlx`. Overrides `COACH_PROVIDER`. |
        | `--model <id>`                                    | No       | Model identifier to use with the selected provider. Overrides `COACH_MODEL`. |
        | `--system-prompt <path>`                          | No       | Path to a markdown file to use as the LLM system message instead of the bundled default. Overrides `COACH_SYSTEM_PROMPT_PATH`. |
        | `--debounce <duration>`                           | No       | Debounce window for stdin mode. Overrides `COACH_DEBOUNCE`. Format: `15s`, `2m`. |
        | `--on-overflow <truncate-start\|truncate-end\|error>` | No | Token-budget overflow strategy. Overrides `COACH_ON_OVERFLOW`. |
        | `--recordings-dir <path>`                         | No       | Directory to scan for the most-recent sidecar in auto-detect mode. Overrides `NTAKKER_RECORDINGS_DIR`. |

        ---

        ## Dependencies (pinned)

        The tool uses LangChain.js for provider abstraction and streaming:

        | Package                  | Version   | Purpose |
        |--------------------------|-----------|---------|
        | `@langchain/core`        | `^1.1.0`  | `BaseChatModel`, message types, `concat` for chunk aggregation |
        | `@langchain/openai`      | `^1.4.0`  | `ChatOpenAI` (direct OpenAI, Azure AI Inference, LiteLLM, MLX-LM via custom `baseURL`) + `AzureChatOpenAI` (legacy Azure deployment-based URLs) |
        | `@langchain/anthropic`   | `^1.3.0`  | `ChatAnthropic` |
        | `@langchain/google-genai`| `^2.1.0`  | `ChatGoogleGenerativeAI` (Gemini) |
        | `@langchain/ollama`      | `^1.2.0`  | `ChatOllama` (native Ollama API) |
        | `js-tiktoken`            | `^1.0.0`  | Token counting for context-window budget |

        npm `overrides` pins `@anthropic-ai/sdk@^0.92.0` to clear an upstream
        moderate-severity advisory (filesystem-memory tool — not used by `convo-coach`).

        ---

        ## Exit codes

        | Code | Meaning |
        |------|---------|
        | 0    | Success — advice streamed to stdout and sidecar written. |
        | 1    | Transcript not found, unreadable, or empty after windowing. |
        | 2    | Configuration error — required variable or flag missing. |
        | 3    | LLM provider error (network failure, auth failure, rate limit). |
        | 4    | Context-window overflow and `--on-overflow error` is active. |
        | 5    | Sidecar write error — output directory not writable. |

        ---

        ## Sidecar output

        For every coaching request, `convo-coach` writes a markdown file named:

            <transcript-basename>.advice-<YYYYMMDD-HHMMSS>.md

        placed in the same directory as the source transcript. The file contains:

        - A YAML front-matter block with `provider`, `model`, `transcript`, `window`, and
          `createdAt` metadata.
        - The full LLM coaching response in markdown body text.
        - A trailing `## Metrics` section with prompt tokens, completion tokens, total tokens,
          time-to-first-token (ms), and total latency (ms).

        ---

        ## Examples

        ### Quick coaching against the most-recent recording (auto-detect)
        ```sh
        convo-coach --provider openai --model gpt-4o-mini
        # Scans ~/Recordings for the newest ntakker-cli sidecar, sends the full transcript.
        ```

        ### Coaching on the last 5 minutes of a specific recording
        ```sh
        convo-coach \
            --transcript ~/Recordings/2026-05-02T09-00-00.jsonl \
            --last 5m \
            --provider anthropic \
            --model claude-haiku-4-5-20251001
        ```

        ### Pipe a live ntakker-cli transcript stream to convo-coach
        ```sh
        tail -f ~/Recordings/live.jsonl | convo-coach --debounce 20s --provider google
        ```

        ### Use a custom system prompt and aggressive overflow handling
        ```sh
        convo-coach \
            --transcript ~/Recordings/sales-call.jsonl \
            --system-prompt ~/prompts/sales-coach.md \
            --on-overflow truncate-start \
            --provider azure-openai
        ```

        ### Coaching with a local Ollama model
        ```sh
        OLLAMA_HOST=http://127.0.0.1:11434 \
        convo-coach --provider ollama --model llama3.1:8b --last 10m
        ```

        ### Coaching through a LiteLLM proxy
        ```sh
        LITELLM_PROXY_URL=http://localhost:4000 \
        convo-coach --provider litellm --model gpt-4o --last 5m
        ```

        ### Coaching with a local MLX-LM server
        ```sh
        # (MLX-LM server started separately with:)
        # mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit
        OPENAI_BASE_URL=http://127.0.0.1:8080 \
        convo-coach --provider mlx --model mlx-community/Llama-3.2-3B-Instruct-4bit
        ```

        ### Pin project-wide defaults in ~/.tool-agents config
        ```sh
        # Edit ~/.tool-agents/convo-coach/.env and set:
        # COACH_PROVIDER=anthropic
        # COACH_MODEL=claude-haiku-4-5-20251001
        # COACH_DEBOUNCE=20s
        #
        # From that point on, bare invocations use Anthropic without any flags.
        convo-coach --transcript ~/Recordings/meeting.jsonl --last 5m
        ```

        ---

        ## Installation

        The tool lives under `tools/convo-coach/` inside the project repository as a
        Node/TypeScript workspace package. Once implemented:

        ```sh
        cd tools/convo-coach
        npm install               # also runs the `prepare` script: tsc + chmod +x dist/cli.js
        npm link                  # installs `convo-coach` on PATH globally

        convo-coach --help
        ```

        `npm link` creates a symlink in your global `bin` directory (e.g.
        `/opt/homebrew/bin/convo-coach` on Apple Silicon Homebrew,
        `~/.npm-global/bin/convo-coach` for user-scoped npm setups). The `prepare` +
        `postbuild` scripts in `package.json` keep the binary executable across rebuilds —
        you do not need to `chmod +x` manually after `npm run build`. To uninstall, run
        `npm unlink -g convo-coach` from anywhere.
    </info>
</convoCoach>
