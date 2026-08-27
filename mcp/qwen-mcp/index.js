#!/usr/bin/env node
/*
 * qwen-mcp - exposes the local Ollama Qwen models to any MCP client as tools.
 *
 * Zero dependencies on purpose: this repo's promise is "clone and run", and an
 * `npm install` step before the server can start would break that. The stdio
 * transport is newline-delimited JSON-RPC 2.0, which is small enough to own.
 *
 * Tools: ask_qwen, list_qwen_models, qwen_health.
 *
 * stdout carries protocol frames ONLY. Everything diagnostic goes to stderr.
 */

import { readFile, realpath, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import path from 'node:path';

const SERVER_NAME = 'qwen-mcp';
const SERVER_VERSION = '1.0.0';

// Newest first. An unknown request falls back to SUPPORTED[0]; every version
// here agrees on the only surface used below (tools/list, tools/call, text).
const SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];

// ------------------------------------------------------------------ config --

function normalizeHost(raw) {
    let h = String(raw || '').trim();
    if (!h) h = 'http://127.0.0.1:11434';
    // OLLAMA_HOST is conventionally written bare ("127.0.0.1:11434").
    if (!/^https?:\/\//i.test(h)) h = 'http://' + h;
    return h.replace(/\/+$/, '');
}

function positiveInt(raw, fallback) {
    const n = Number.parseInt(raw, 10);
    return Number.isFinite(n) && n > 0 ? n : fallback;
}

const OLLAMA = normalizeHost(process.env.OLLAMA_HOST);
const GEN_TIMEOUT_MS = positiveInt(process.env.QWEN_MCP_TIMEOUT, 900) * 1000;
const PROBE_TIMEOUT_MS = 10000;
const DEFAULT_MODEL = (process.env.QWEN_MCP_MODEL || 'qwen-coder').trim();

// Files may only be read from inside this root. Claude Code starts an MCP server
// with the project directory as cwd, so that is the natural sandbox.
const ROOT_RAW = path.resolve(process.env.QWEN_MCP_ROOT || process.cwd());

const LIMITS = {
    promptChars: 100000,
    files: 20,
    fileBytes: 256 * 1024,
    totalFileBytes: 1024 * 1024,
    maxTokens: 32768,
    numCtxMin: 512,
    numCtxMax: 262144,
    rpcLineBytes: 16 * 1024 * 1024
};

// A tool failed at runtime (Ollama down, timeout, bad file). Reported back as
// an MCP tool error so the calling model can read it and adapt.
class ToolFailure extends Error {}

// The arguments themselves were wrong. Reported as JSON-RPC -32602.
class InvalidParams extends Error {}

// ------------------------------------------------------------------- http ---

async function httpJson(url, { method = 'GET', body, timeoutMs = PROBE_TIMEOUT_MS } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res;
    try {
        res = await fetch(url, {
            method,
            signal: controller.signal,
            headers: body ? { 'content-type': 'application/json' } : undefined,
            body: body ? JSON.stringify(body) : undefined
        });
    } catch (err) {
        if (err && err.name === 'AbortError') {
            throw new ToolFailure(
                `Timed out after ${Math.round(timeoutMs / 1000)}s waiting for Ollama at ${OLLAMA}. ` +
                'A big model on a weak box can genuinely take this long: raise QWEN_MCP_TIMEOUT ' +
                '(seconds), lower max_tokens, or switch to a smaller model.'
            );
        }
        throw new ToolFailure(
            `Cannot reach Ollama at ${OLLAMA} (${err && err.message ? err.message : err}). ` +
            'Start it with "%LOCALAPPDATA%\\Programs\\Ollama\\ollama.exe serve" - the tray app does ' +
            'not always start the server. Set OLLAMA_HOST if it listens elsewhere.'
        );
    } finally {
        clearTimeout(timer);
    }

    const text = await res.text();
    let parsed = null;
    try { parsed = text ? JSON.parse(text) : null; } catch { /* handled below */ }

    if (!res.ok) {
        const detail = (parsed && parsed.error) ? JSON.stringify(parsed.error) : text.slice(0, 500);
        const err = new ToolFailure(`Ollama returned HTTP ${res.status}: ${detail}`);
        err.status = res.status;
        throw err;
    }
    if (parsed === null) throw new ToolFailure(`Ollama returned unparseable JSON: ${text.slice(0, 300)}`);
    return parsed;
}

async function installedTags() {
    const tags = await httpJson(`${OLLAMA}/api/tags`);
    return Array.isArray(tags.models) ? tags.models : [];
}

// ------------------------------------------------------------ file context --

function isInside(root, target) {
    const rel = path.relative(root, target);
    if (rel === '') return true;
    if (path.isAbsolute(rel)) return false;
    return !rel.split(path.sep).includes('..');
}

async function resolveRoot() {
    try { return await realpath(ROOT_RAW); } catch { return ROOT_RAW; }
}

async function readContextFiles(files) {
    const root = await resolveRoot();
    const out = [];
    let total = 0;

    for (const raw of files) {
        if (typeof raw !== 'string' || !raw.trim()) throw new InvalidParams('files[] entries must be non-empty strings.');
        const abs = path.resolve(root, raw);
        const escaped = `Refusing to read ${raw}: it resolves outside the sandbox root ${root}. Set QWEN_MCP_ROOT to widen it.`;
        // Check the lexical path first so an escape is reported as a refusal even
        // when the target does not exist, then again after realpath so a symlink
        // cannot smuggle a path out of the root.
        if (!isInside(root, abs)) throw new ToolFailure(escaped);

        let real;
        try {
            real = await realpath(abs);
        } catch {
            throw new ToolFailure(`File not found: ${raw} (resolved to ${abs}).`);
        }
        if (!isInside(root, real)) throw new ToolFailure(escaped);

        const info = await stat(real);
        if (info.isDirectory()) throw new ToolFailure(`${raw} is a directory, not a file.`);
        if (info.size > LIMITS.fileBytes) {
            throw new ToolFailure(`${raw} is ${Math.round(info.size / 1024)} KB, over the ${LIMITS.fileBytes / 1024} KB per-file cap. Pass an excerpt in the prompt instead.`);
        }
        total += info.size;
        if (total > LIMITS.totalFileBytes) {
            throw new ToolFailure(`Attached files exceed the ${LIMITS.totalFileBytes / 1024} KB total cap. Send fewer files.`);
        }

        const text = await readFile(real, 'utf8');
        if (text.includes('\0')) throw new ToolFailure(`${raw} looks binary, not text.`);
        out.push({ label: path.relative(root, real) || path.basename(real), text });
    }
    return out;
}

function buildUserMessage(prompt, contextFiles) {
    if (contextFiles.length === 0) return prompt;
    const blocks = contextFiles.map(f =>
        `--- FILE: ${f.label} (${f.text.split('\n').length} lines) ---\n${f.text}\n--- END FILE: ${f.label} ---`
    );
    return `${blocks.join('\n\n')}\n\n${prompt}`;
}

// --------------------------------------------------------------- ask_qwen ---

function requireString(args, key, { required = false, max = 0 } = {}) {
    const v = args[key];
    if (v === undefined || v === null) {
        if (required) throw new InvalidParams(`"${key}" is required.`);
        return undefined;
    }
    if (typeof v !== 'string') throw new InvalidParams(`"${key}" must be a string.`);
    if (required && !v.trim()) throw new InvalidParams(`"${key}" must not be empty.`);
    if (max && v.length > max) throw new InvalidParams(`"${key}" is ${v.length} chars, over the ${max} char cap.`);
    return v;
}

function requireNumber(args, key, min, max, { integer = false } = {}) {
    const v = args[key];
    if (v === undefined || v === null) return undefined;
    if (typeof v !== 'number' || !Number.isFinite(v)) throw new InvalidParams(`"${key}" must be a number.`);
    if (integer && !Number.isInteger(v)) throw new InvalidParams(`"${key}" must be an integer.`);
    if (v < min || v > max) throw new InvalidParams(`"${key}" must be between ${min} and ${max}.`);
    return v;
}

function parseAskArgs(args) {
    const prompt = requireString(args, 'prompt', { required: true, max: LIMITS.promptChars });
    const model = requireString(args, 'model') || DEFAULT_MODEL;
    const system = requireString(args, 'system', { max: LIMITS.promptChars });
    const maxTokens = requireNumber(args, 'max_tokens', 1, LIMITS.maxTokens, { integer: true });
    const temperature = requireNumber(args, 'temperature', 0, 2);
    const numCtx = requireNumber(args, 'num_ctx', LIMITS.numCtxMin, LIMITS.numCtxMax, { integer: true });

    let files = args.files;
    if (files === undefined || files === null) files = [];
    if (!Array.isArray(files)) throw new InvalidParams('"files" must be an array of paths.');
    if (files.length > LIMITS.files) throw new InvalidParams(`"files" holds ${files.length} entries, over the ${LIMITS.files} file cap.`);

    const includeReasoning = args.include_reasoning === undefined ? false : args.include_reasoning;
    if (typeof includeReasoning !== 'boolean') throw new InvalidParams('"include_reasoning" must be a boolean.');

    return {
        prompt,
        model,
        system,
        files,
        includeReasoning,
        maxTokens: maxTokens === undefined ? 2048 : maxTokens,
        temperature: temperature === undefined ? 0.2 : temperature,
        numCtx
    };
}

// One generation at a time. The box has a single GPU and Ollama queues anyway,
// so overlapping calls buy nothing and just multiply VRAM pressure. This mutex
// wraps ONLY generate(), so ping, tools/list, qwen_health and list_qwen_models
// keep answering while a long generation runs - a client whose ping goes
// unanswered past its connection timeout declares the server dead.
let genQueue = Promise.resolve();
function serializeGeneration(fn) {
    const run = genQueue.then(fn, fn);
    // The queue itself must never reject, or one failure would poison the rest.
    genQueue = run.then(function () {}, function () {});
    return run;
}

// Two endpoints, one shape out. /v1 is the default path, but its request schema
// has no num_ctx field and silently drops the key (verified against 0.32.15), so
// an explicit num_ctx has to go through the native endpoint to take effect.
async function generate(opts) {
    const messages = [];
    if (opts.system) messages.push({ role: 'system', content: opts.system });
    messages.push({ role: 'user', content: opts.userMessage });

    const started = Date.now();

    if (opts.numCtx === undefined) {
        const body = {
            model: opts.model,
            messages,
            stream: false,
            max_tokens: opts.maxTokens,
            temperature: opts.temperature
        };
        const r = await httpJson(`${OLLAMA}/v1/chat/completions`, { method: 'POST', body, timeoutMs: GEN_TIMEOUT_MS });
        const choice = (r.choices && r.choices[0]) || {};
        const msg = choice.message || {};
        return {
            endpoint: '/v1/chat/completions',
            // Qwen3.8 puts chain-of-thought in a separate `reasoning` field, so
            // content arrives clean - no <think> stripping needed.
            content: typeof msg.content === 'string' ? msg.content : '',
            reasoning: typeof msg.reasoning === 'string' ? msg.reasoning : '',
            finishReason: choice.finish_reason || 'unknown',
            outTokens: (r.usage && r.usage.completion_tokens) || 0,
            inTokens: (r.usage && r.usage.prompt_tokens) || 0,
            wallSeconds: (Date.now() - started) / 1000,
            genTps: null
        };
    }

    const body = {
        model: opts.model,
        messages,
        stream: false,
        options: { num_ctx: opts.numCtx, num_predict: opts.maxTokens, temperature: opts.temperature }
    };
    const r = await httpJson(`${OLLAMA}/api/chat`, { method: 'POST', body, timeoutMs: GEN_TIMEOUT_MS });
    const msg = r.message || {};
    const tps = (r.eval_count && r.eval_duration) ? r.eval_count / (r.eval_duration / 1e9) : null;
    return {
        endpoint: '/api/chat',
        content: typeof msg.content === 'string' ? msg.content : '',
        // The native endpoint names the same field `thinking`.
        reasoning: typeof msg.thinking === 'string' ? msg.thinking : '',
        finishReason: r.done_reason || 'unknown',
        outTokens: r.eval_count || 0,
        inTokens: r.prompt_eval_count || 0,
        wallSeconds: (Date.now() - started) / 1000,
        genTps: tps === null ? null : Math.round(tps * 10) / 10
    };
}

async function unknownModelHelp(model) {
    let names = [];
    try {
        names = (await installedTags()).map(m => m.name);
    } catch { /* the tag listing is a nicety; do not mask the original failure */ }
    const list = names.length ? `Installed tags: ${names.join(', ')}.` : 'Could not list installed tags.';
    return `Model "${model}" is not available on this Ollama instance. ${list} ` +
           'Call list_qwen_models to choose one, or pull it first.';
}

async function askQwen(rawArgs) {
    const opts = parseAskArgs(rawArgs);
    const contextFiles = await readContextFiles(opts.files);
    const userMessage = buildUserMessage(opts.prompt, contextFiles);

    let result;
    try {
        result = await serializeGeneration(() => generate({ ...opts, userMessage }));
    } catch (err) {
        if (err instanceof ToolFailure && err.status === 404) throw new ToolFailure(await unknownModelHelp(opts.model));
        throw err;
    }

    // A thinking model can spend the whole budget reasoning and return nothing.
    // Silently handing back "" would look like a broken tool, so say what happened.
    if (!result.content.trim()) {
        if (result.reasoning.trim()) {
            throw new ToolFailure(
                `${opts.model} used its entire ${opts.maxTokens}-token budget on reasoning and produced no answer. ` +
                'Raise max_tokens, or use a non-thinking model such as qwen-coder. ' +
                `First 300 chars of the reasoning: ${result.reasoning.trim().slice(0, 300)}`
            );
        }
        throw new ToolFailure(`${opts.model} returned an empty response (finish_reason=${result.finishReason}).`);
    }

    const rate = result.genTps !== null
        ? `${result.genTps} tok/s`
        : `${(result.outTokens / Math.max(result.wallSeconds, 0.1)).toFixed(1)} tok/s wall`;
    const meta = [
        `model=${opts.model}`,
        `endpoint=${result.endpoint}`,
        `in=${result.inTokens} out=${result.outTokens} tok`,
        `${result.wallSeconds.toFixed(1)}s (${rate})`,
        `finish=${result.finishReason}`,
        contextFiles.length ? `files=${contextFiles.length}` : null,
        opts.numCtx ? `num_ctx=${opts.numCtx}` : null
    ].filter(Boolean).join(' | ');

    const content = [{ type: 'text', text: result.content }];
    if (opts.includeReasoning && result.reasoning.trim()) {
        content.push({ type: 'text', text: `--- reasoning ---\n${result.reasoning}` });
    }
    content.push({ type: 'text', text: `--- qwen: ${meta}` });
    return { content };
}

// -------------------------------------------------------- list_qwen_models --

function gpuVram() {
    // nvidia-smi is the only trustworthy source: Win32_VideoController.AdapterRAM
    // is a uint32 and wraps at 4 GB.
    return new Promise(resolve => {
        execFile('nvidia-smi',
            ['--query-gpu=name,memory.total,memory.free', '--format=csv,noheader,nounits'],
            { timeout: 5000, windowsHide: true },
            (err, stdout) => {
                if (err || !stdout) return resolve(null);
                const f = String(stdout).split('\n')[0].split(',').map(s => s.trim());
                const total = Number.parseInt(f[1], 10);
                if (!Number.isFinite(total)) return resolve(null);
                resolve({ name: f[0], totalMB: total, freeMB: Number.parseInt(f[2], 10) || 0 });
            });
    });
}

const GB = 1024 * 1024 * 1024;
const round1 = n => Math.round(n * 10) / 10;

async function listQwenModels() {
    const [models, gpu] = await Promise.all([installedTags(), gpuVram()]);

    // Same 1.5 GB desktop/KV reserve detect-hardware.ps1 uses, so the two agree.
    const usableVramGB = gpu ? round1(Math.max(0, gpu.totalMB - 1536) / 1024) : 0;

    const rows = models.map(m => {
        const d = m.details || {};
        const families = d.families || (d.family ? [d.family] : []);
        const moe = families.some(f => /moe/i.test(f));
        const sizeGB = round1(m.size / GB);
        // Weights plus a small allowance for a modest KV cache. Deliberately not
        // bigger: measured on an 8 GB card, a 5.8 GB tag sits fully in VRAM at
        // ctx 8192. What breaks the fit is context length, which is called out
        // in the note rather than baked into a pessimistic multiplier.
        const needGB = round1(sizeGB * 1.05);
        const fits = usableVramGB > 0 ? needGB <= usableVramGB : false;
        return {
            name: m.name,
            sizeGB,
            family: families.join(',') || 'unknown',
            architecture: moe ? 'MoE (few active params per token)' : 'dense (all params active per token)',
            parameterSize: d.parameter_size || 'unknown',
            quantization: d.quantization_level || 'unknown',
            trainedContext: d.context_length || null,
            estimatedVramNeedGB: needGB,
            fitsVram: fits,
            note: !gpu
                ? 'No NVIDIA GPU detected - everything runs on CPU.'
                : fits
                    ? 'Fits in VRAM at a modest context. Raising num_ctx can still push it out, and on ' +
                      'Windows that pages over PCIe instead of failing - throughput collapses while the ' +
                      'split still reads 100% GPU.'
                    : moe
                        ? 'Spills to RAM, but only the active experts stream per token, so it stays usable.'
                        : 'Spills to RAM and is dense, so every weight streams per token - expect a few tok/s.'
        };
    }).sort((a, b) => a.sizeGB - b.sizeGB);

    const payload = {
        ollamaHost: OLLAMA,
        defaultModel: DEFAULT_MODEL,
        gpu: gpu ? { name: gpu.name, vramTotalMB: gpu.totalMB, vramFreeMB: gpu.freeMB, usableVramGB } : null,
        models: rows,
        guidance: 'When a model will not fit in VRAM, prefer MoE over a dense model of similar size: ' +
                  'a dense model that spills is bandwidth-bound and collapses to a few tok/s, while an ' +
                  'MoE model only moves its active experts. Size on disk is a poor predictor of speed.'
    };
    return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }] };
}

// -------------------------------------------------------------- qwen_health --

function processorSplit(m) {
    const size = m.size || 0;
    const vram = m.size_vram || 0;
    if (!size) return 'unknown';
    if (vram === 0) return '100% CPU';
    if (vram >= size) return '100% GPU';
    const gpuPct = Math.round((vram / size) * 100);
    return `${100 - gpuPct}% CPU / ${gpuPct}% GPU`;
}

async function qwenHealth() {
    const version = await httpJson(`${OLLAMA}/api/version`);
    const ps = await httpJson(`${OLLAMA}/api/ps`);
    const loaded = (ps.models || []).map(m => ({
        name: m.name,
        processorSplit: processorSplit(m),
        contextLength: m.context_length || null,
        residentGB: round1((m.size || 0) / GB),
        vramGB: round1((m.size_vram || 0) / GB),
        expiresAt: m.expires_at || null
    }));

    const payload = {
        reachable: true,
        ollamaHost: OLLAMA,
        ollamaVersion: version.version || 'unknown',
        defaultModel: DEFAULT_MODEL,
        generationTimeoutSeconds: GEN_TIMEOUT_MS / 1000,
        fileSandboxRoot: await resolveRoot(),
        loadedModels: loaded,
        note: loaded.length === 0
            ? 'No model is resident. The first ask_qwen call pays the load cost (tens of seconds).'
            : 'A split that is not 100% GPU means weights stream from RAM. On Windows an overshoot of ' +
              'VRAM can still report 100% GPU while the driver pages over PCIe - if a model that should ' +
              'fit is inexplicably slow, lower num_ctx first.'
    };
    return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }] };
}

// -------------------------------------------------------------- tool table --

const TOOLS = [
    {
        name: 'ask_qwen',
        description:
            'Ask a locally hosted Qwen model (via Ollama) a question and get its text back. ' +
            'Nothing leaves the machine. Use it to offload bulk, low-stakes generation - docstrings, ' +
            'test scaffolds, summarising long output, boilerplate - and review the text before acting ' +
            'on it. This tool never touches files; it only reads the ones listed in "files". ' +
            'Expect tens of seconds to several minutes: local generation is slow.',
        inputSchema: {
            type: 'object',
            properties: {
                prompt: { type: 'string', description: 'The instruction for the model. Required, non-empty.' },
                model: { type: 'string', description: `Ollama tag, e.g. qwen-coder (30B MoE, good at code) or qwen38-9b (fast, fits in VRAM). Default: ${DEFAULT_MODEL}. Call list_qwen_models to see what is installed.` },
                files: { type: 'array', items: { type: 'string' }, description: `Paths to text files to prepend as context, relative to the server's working directory. Max ${LIMITS.files} files, ${LIMITS.fileBytes / 1024} KB each.` },
                system: { type: 'string', description: 'Optional system prompt.' },
                max_tokens: { type: 'integer', minimum: 1, maximum: LIMITS.maxTokens, description: 'Output token cap. Default 2048. Thinking models spend this budget on reasoning first, so do not set it low for them.' },
                temperature: { type: 'number', minimum: 0, maximum: 2, description: 'Sampling temperature. Default 0.2.' },
                num_ctx: { type: 'integer', minimum: LIMITS.numCtxMin, maximum: LIMITS.numCtxMax, description: 'Override the context window. Routed through Ollama\'s native endpoint because the OpenAI-compatible one ignores it, and forces a model reload. Leave unset to use the tag\'s own setting.' },
                include_reasoning: { type: 'boolean', description: 'Also return the model\'s reasoning trace as a second block. Default false.' }
            },
            required: ['prompt'],
            additionalProperties: false
        }
    },
    {
        name: 'list_qwen_models',
        description:
            'List the models installed in the local Ollama, with size, family, MoE-vs-dense architecture ' +
            'and whether each one fits in this machine\'s VRAM. Call this before choosing a model for ask_qwen.',
        inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    },
    {
        name: 'qwen_health',
        description:
            'Check that the local Ollama server is reachable, report its version, and show which model is ' +
            'currently resident along with its GPU/CPU split. Use it first when ask_qwen misbehaves.',
        inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    }
];

const HANDLERS = {
    ask_qwen: askQwen,
    list_qwen_models: listQwenModels,
    qwen_health: qwenHealth
};

// ---------------------------------------------------------------- jsonrpc ---

function send(msg) {
    process.stdout.write(JSON.stringify(msg) + '\n');
}

function replyResult(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function dispatch(msg) {
    const { id, method, params } = msg;
    const isNotification = id === undefined || id === null;

    switch (method) {
        case 'initialize': {
            const asked = params && params.protocolVersion;
            const version = SUPPORTED_PROTOCOLS.includes(asked) ? asked : SUPPORTED_PROTOCOLS[0];
            replyResult(id, {
                protocolVersion: version,
                capabilities: { tools: { listChanged: false } },
                serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
            });
            return;
        }
        case 'notifications/initialized':
        case 'notifications/cancelled':
            return;                                  // notifications get no reply
        case 'ping':
            if (!isNotification) replyResult(id, {});
            return;
        case 'tools/list':
            replyResult(id, { tools: TOOLS });
            return;
        case 'tools/call': {
            const name = params && params.name;
            const handler = HANDLERS[name];
            if (!handler) {
                replyError(id, -32602, `Unknown tool "${name}". Available: ${Object.keys(HANDLERS).join(', ')}.`);
                return;
            }
            const args = (params && params.arguments) || {};
            if (typeof args !== 'object' || Array.isArray(args)) {
                replyError(id, -32602, 'Tool arguments must be an object.');
                return;
            }
            try {
                replyResult(id, await handler(args));
            } catch (err) {
                if (err instanceof InvalidParams) {
                    replyError(id, -32602, err.message);
                } else if (err instanceof ToolFailure) {
                    // Runtime trouble is a tool result, not a protocol fault: the
                    // calling model can read it and pick a different model or retry.
                    replyResult(id, { isError: true, content: [{ type: 'text', text: err.message }] });
                } else {
                    replyResult(id, { isError: true, content: [{ type: 'text', text: `qwen-mcp internal error: ${err && err.stack ? err.stack : err}` }] });
                }
            }
            return;
        }
        default:
            if (!isNotification) replyError(id, -32601, `Method not found: ${method}`);
    }
}

async function handleLine(line) {
    let msg;
    try {
        msg = JSON.parse(line);
    } catch {
        replyError(null, -32700, 'Parse error: not valid JSON.');
        return;
    }
    if (Array.isArray(msg)) {
        for (const m of msg) await dispatch(m);      // pre-2025-06-18 batching
        return;
    }
    if (!msg || typeof msg !== 'object' || msg.jsonrpc !== '2.0') {
        replyError(msg && msg.id !== undefined ? msg.id : null, -32600, 'Invalid Request: expected a JSON-RPC 2.0 object.');
        return;
    }
    await dispatch(msg);
}

let buffer = '';

// Every handler still running. Requests are dispatched concurrently: send() is
// one synchronous stdout.write of a complete frame, so frames cannot interleave
// and a global queue protects nothing while starving liveness probes. The set
// exists so a stdin close can drain rather than cut an in-flight handler off
// without a reply.
const inFlight = new Set();

function dispatchLine(line) {
    const p = handleLine(line).catch(e => process.stderr.write('qwen-mcp: ' + (e && e.stack ? e.stack : e) + '\n'));
    inFlight.add(p);
    p.then(() => inFlight.delete(p));
}

// Loop, because a handler settling can be what lets the next one be added.
async function drain() {
    while (inFlight.size > 0) await Promise.all(Array.from(inFlight));
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
    buffer += chunk;
    if (buffer.length > LIMITS.rpcLineBytes) {
        buffer = '';
        replyError(null, -32600, 'Invalid Request: message exceeded the 16 MB frame cap.');
        return;
    }
    let nl;
    while ((nl = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (line) dispatchLine(line);
    }
});

// Exiting the instant stdin closes discards every handler still awaiting the
// filesystem or Ollama - only work that settles on the microtask queue would
// ever reply, which is why a piped tools/call used to print nothing. Drain
// first. The wait is bounded by GEN_TIMEOUT_MS, which aborts the longest thing
// that can be in flight.
process.stdin.on('end', () => { drain().then(() => process.exit(0), () => process.exit(0)); });

// A drained but orphaned server can finish writing into a pipe whose reader has
// gone. EPIPE there is expected, not a crash.
process.stdout.on('error', () => {});
process.on('uncaughtException', e => { process.stderr.write(`qwen-mcp uncaught: ${e && e.stack ? e.stack : e}\n`); });
process.on('unhandledRejection', e => { process.stderr.write(`qwen-mcp unhandled: ${e && e.stack ? e.stack : e}\n`); });

process.stderr.write(`qwen-mcp ${SERVER_VERSION} ready - ollama=${OLLAMA} default=${DEFAULT_MODEL} timeout=${GEN_TIMEOUT_MS / 1000}s root=${ROOT_RAW}\n`);
