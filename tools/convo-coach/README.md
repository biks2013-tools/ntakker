# convo-coach

LLM-powered conversational coach for ntakker-cli transcripts. Reads a ntakker-cli
sidecar (JSONL/TXT/SRT/VTT), windows the most relevant segments, and streams
coaching advice from one of eight LLM providers.

For full documentation — CLI flags, environment variables, provider setup,
exit codes, troubleshooting — see
[`docs/tools/convo-coach.md`](../../docs/tools/convo-coach.md).

## Install

```sh
cd tools/convo-coach
npm install              # also runs `prepare`: tsc + chmod +x dist/cli.js
npm link                 # installs `convo-coach` on PATH globally
convo-coach --help
```

To uninstall the global symlink: `npm unlink -g convo-coach`.
