import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupExpiredDownloads, MAX_JOB_AGE_MS, progressFromLine, validateMediaUrl } from "../server.mjs";

test("accepts only supported YouTube hosts", () => {
  assert.equal(validateMediaUrl("https://youtu.be/abc"), "https://youtu.be/abc");
  assert.equal(validateMediaUrl("https://music.youtube.com/watch?v=abc"), "https://music.youtube.com/watch?v=abc");
  assert.throws(() => validateMediaUrl("https://youtube.com.evil.example/watch?v=abc"));
  assert.throws(() => validateMediaUrl("file:///tmp/example.mp3"));
});

test("parses and clamps yt-dlp progress", () => {
  assert.equal(progressFromLine("[download]  42.6% of 4.00MiB"), 43);
  assert.equal(progressFromLine("unrelated"), null);
});

test("removes expired download folders left by an earlier process", () => {
  const root = mkdtempSync(join(tmpdir(), "cadenza-cleanup-"));
  const expired = join(root, "expired-job");
  const recent = join(root, "recent-job");
  const now = Date.now();
  mkdirSync(expired);
  mkdirSync(recent);
  const expiredAt = new Date(now - MAX_JOB_AGE_MS - 1_000);
  utimesSync(expired, expiredAt, expiredAt);

  try {
    cleanupExpiredDownloads(root, now);
    assert.equal(existsSync(expired), false);
    assert.equal(existsSync(recent), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
