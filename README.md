# ai-stack

Local AI plumbing for a Windows dev machine: which model each tool talks to, and the
secrets that connect them.

```
n8n    ──►  Ollama (127.0.0.1:11434) ──┬──► gpt-oss:120b-cloud / gemma4:cloud  (Ollama Cloud, free tier)
                                       └──► qwen3:4b                            (local CPU, fully offline)
Cline  ──►  omniroute (127.0.0.1:20128)  combo "coding" (priority, first healthy wins):
                1. ollama-local/gpt-oss:120b-cloud        Ollama Cloud
                2. ollama-local/gemma4:cloud              Ollama Cloud
                3. groq/openai/gpt-oss-120b               Groq
                4. groq/qwen/qwen3.8-27b                  Groq
                5. nvidia/nvidia/nemotron-3-super-120b-a12b   NVIDIA
                6. gemini/gemini-3-flash-preview          Gemini (free tier trains on prompts)
                7. gemini/gemini-3.1-flash-lite           Gemini
```

Combo "private" (for work that may touch private data; no-training providers only):
ollama gpt-oss:120b-cloud → ollama gemma4:cloud → groq gpt-oss-120b →
groq qwen3.8-27b → cloudflare @cf/openai/gpt-oss-120b → cloudflare
@cf/qwen/qwen3.8-27b → ollama qwen3:4b (local, slow, last resort).
Cloudflare model ids need the `@cf/` prefix; the Workers Free plan
(10k neurons/day) excludes Kimi and GLM.
`coding` is for low-stakes sandbox work only: it can fall through to NVIDIA (trial terms say
"not for production") and Gemini free (trains on prompts).

Tested 2026-09-21. omniroute's model catalog lags the providers: query
`/v1/models` on each provider for the live list before adding a model. Dead
ends found: NVIDIA GLM-5.3 / Kimi-K3 queue past 90s on the free tier; Gemini
2.5 Pro/Flash are closed to new keys; Gemini 3.1 Pro rate-limits immediately.

Cline: provider *OpenAI Compatible*, base URL `http://127.0.0.1:20128/v1`,
API key `OMNIROUTE_CLINE_KEY` from `.env`, model `coding`.

Ollama Cloud free tier on this account (tested 2026-09-21): `gpt-oss:120b-cloud`,
`gpt-oss:20b-cloud`, `gemma4:cloud`, `nemotron-3-nano:30b-cloud`. Metered by GPU
time (5-hour session + weekly limits). Everything else (GLM, Kimi, DeepSeek,
Qwen 3.5, MiniMax) returns HTTP 402 without paid credits.

## Run

- **Ollama** starts at logon. Models: `ollama list`.
- **omniroute**: `omniroute serve --no-open` → dashboard at http://localhost:20128
- **n8n**: `n8n start` → http://localhost:5678, Ctrl+C to stop.

## Secrets

Fill in `.env`, then
`powershell -ExecutionPolicy Bypass -File apply-secrets.ps1`. The script pipes
keys into omniroute over stdin and never prints them. `.env` is gitignored.

## Why it is shaped this way

- n8n talks to Ollama directly so its traffic never leaves the machine.
- Cline goes through omniroute so the model behind it can change without
  touching Cline's settings.
- No `auto` routing: its default pool includes keyless providers nobody here
  has vetted. Every route is an explicit combo.
- omniroute binds `127.0.0.1` and requires an API key on `/v1`
  (`~\.omniroute\.env`); n8n binds loopback via `N8N_LISTEN_ADDRESS`.
