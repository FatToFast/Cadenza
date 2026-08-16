import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, readdirSync, rmSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";

const HOST = process.env.CADENZA_MEDIA_HOST || "127.0.0.1";
const PORT = Number(process.env.CADENZA_MEDIA_PORT || 8899);
const ROOT = resolve(process.env.CADENZA_MEDIA_DIR || join(import.meta.dirname, "downloads"));
const YTDLP = process.env.CADENZA_YTDLP || "yt-dlp";
const jobs = new Map();
const allowedHosts = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]);
export const MAX_JOB_AGE_MS = 24 * 60 * 60 * 1_000;

mkdirSync(ROOT, { recursive: true });

export function validateMediaUrl(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("올바른 YouTube URL을 입력하세요");
  }
  if (!["https:", "http:"].includes(parsed.protocol) || !allowedHosts.has(parsed.hostname.toLowerCase())) {
    throw new Error("YouTube 또는 youtu.be 주소만 사용할 수 있습니다");
  }
  return parsed.toString();
}

export function progressFromLine(line) {
  const match = line.match(/\[download\]\s+([\d.]+)%/);
  return match ? Math.max(0, Math.min(100, Math.round(Number(match[1])))) : null;
}

export function cleanupExpiredDownloads(root = ROOT, now = Date.now()) {
  const cutoff = now - MAX_JOB_AGE_MS;
  if (existsSync(root)) {
    for (const entry of readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const directory = join(root, entry.name);
      try {
        if (statSync(directory).mtimeMs < cutoff) {
          rmSync(directory, { recursive: true, force: true });
        }
      } catch {
        // A job may finish or be removed while cleanup is inspecting it.
      }
    }
  }
  for (const [id, job] of jobs) {
    if (job.createdAt < cutoff) jobs.delete(id);
  }
}

function json(response, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": data.length,
    "Cache-Control": "no-store",
  });
  response.end(data);
}

async function readJson(request) {
  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 8_192) throw new Error("요청이 너무 큽니다");
  }
  return JSON.parse(body || "{}");
}

function publicJob(job) {
  return {
    id: job.id,
    status: job.status,
    progress: job.progress,
    filename: job.file ? basename(job.file) : undefined,
    error: job.error,
  };
}

function runJob(job, mediaUrl) {
  const jobDir = join(ROOT, job.id);
  mkdirSync(jobDir, { recursive: true });
  job.status = "downloading";

  const args = [
    "--no-playlist",
    "--newline",
    "--no-warnings",
    "--restrict-filenames",
    "--max-filesize", "250M",
    "--match-filter", "duration <= 1800",
    "--extract-audio",
    "--audio-format", "mp3",
    "--audio-quality", "0",
    "--embed-metadata",
    "--output", join(jobDir, "%(title).150B_[%(id)s].%(ext)s"),
    mediaUrl,
  ];

  const child = spawn(YTDLP, args, { stdio: ["ignore", "pipe", "pipe"] });
  const recentOutput = [];
  const consume = (chunk) => {
    for (const line of chunk.toString().split(/\r?\n/)) {
      if (line.trim()) {
        recentOutput.push(line.trim());
        if (recentOutput.length > 12) recentOutput.shift();
      }
      const progress = progressFromLine(line);
      if (progress !== null) job.progress = progress;
    }
  };
  child.stdout.on("data", consume);
  child.stderr.on("data", consume);
  child.on("error", (error) => {
    job.status = "failed";
    job.error = `yt-dlp 실행 실패: ${error.message}`;
  });
  child.on("close", (code) => {
    if (job.status === "failed") return;
    const file = existsSync(jobDir)
      ? readdirSync(jobDir).map((name) => join(jobDir, name)).find((candidate) => candidate.endsWith(".mp3"))
      : undefined;
    if (code === 0 && file) {
      job.status = "ready";
      job.progress = 100;
      job.file = file;
    } else {
      job.status = "failed";
      const detail = recentOutput.findLast((line) => /ERROR:|unavailable|exceeded/i.test(line));
      job.error = detail?.slice(0, 400) || "MP3 변환에 실패했습니다. URL 또는 영상 제한을 확인하세요";
    }
  });
}

export function createCadenzaServer() {
  return createServer(async (request, response) => {
    const requestUrl = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
    try {
      if (request.method === "GET" && requestUrl.pathname === "/") {
        return json(response, 200, { name: "Cadenza Media Server", status: "ok" });
      }

      if (request.method === "POST" && requestUrl.pathname === "/api/download") {
        const body = await readJson(request);
        const mediaUrl = validateMediaUrl(body.url);
        const id = randomUUID();
        const job = { id, status: "queued", progress: 0, createdAt: Date.now() };
        jobs.set(id, job);
        runJob(job, mediaUrl);
        return json(response, 202, publicJob(job));
      }

      const match = requestUrl.pathname.match(/^\/api\/jobs\/([0-9a-f-]+)(\/file)?$/);
      if (request.method === "GET" && match) {
        const job = jobs.get(match[1]);
        if (!job) return json(response, 404, { error: "작업을 찾을 수 없습니다" });
        if (!match[2]) return json(response, 200, publicJob(job));
        if (job.status !== "ready" || !job.file || !existsSync(job.file)) {
          return json(response, 409, { error: "파일이 아직 준비되지 않았습니다" });
        }
        const size = statSync(job.file).size;
        response.writeHead(200, {
          "Content-Type": "audio/mpeg",
          "Content-Length": size,
          "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(basename(job.file))}`,
          "Cache-Control": "private, no-store",
        });
        return createReadStream(job.file).pipe(response);
      }

      return json(response, 404, { error: "Not found" });
    } catch (error) {
      return json(response, 400, { error: error.message || "잘못된 요청입니다" });
    }
  });
}

cleanupExpiredDownloads();
setInterval(() => cleanupExpiredDownloads(), 60 * 60 * 1_000).unref();

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createCadenzaServer().listen(PORT, HOST, () => {
    console.log(`Cadenza Media Server listening on http://${HOST}:${PORT}`);
  });
}
