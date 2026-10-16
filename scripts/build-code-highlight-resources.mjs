#!/usr/bin/env node
// 生成只读代码着色所需的离线资源：highlight.js 核心、全部内置语法与 Zig 语法合成为一个自包含 Worker 脚本。
// 这是显式的维护动作：应用构建与启动不下载、不执行 npm。升级依赖时修改下方版本号并重新运行。
//
// 用法：node scripts/build-code-highlight-resources.mjs [工作目录，默认为系统临时目录下的新目录]

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const HIGHLIGHT_VERSION = "11.12.0";
const ZIG_VERSION = "1.0.2";
const EXPECTED_LANGUAGE_COUNT = 194;

const scriptDir = dirname(fileURLToPath(import.meta.url));
const outputDir = resolve(scriptDir, "../foofoil/Resources/CodePreview");
const workDir = resolve(process.argv[2] ?? mkdtempSync(join(tmpdir(), "foofoil-hljs-")));
mkdirSync(workDir, { recursive: true });

function extractTarball(name, version) {
    const tarball = execFileSync("npm", ["pack", `${name}@${version}`, "--silent"], { cwd: workDir, encoding: "utf8" }).trim();
    const directory = join(workDir, `${name.replace("/", "-")}-${version}`);
    mkdirSync(directory, { recursive: true });
    execFileSync("tar", ["xzf", join(workDir, tarball), "-C", directory], { stdio: "ignore" });
    return join(directory, "package");
}

const coreRoot = extractTarball("@highlightjs/cdn-assets", HIGHLIGHT_VERSION);
const zigRoot = extractTarball("highlightjs-zig", ZIG_VERSION);

const coreSource = readFileSync(join(coreRoot, "es/core.min.js"), "utf8").trimEnd();
const exportTail = "export{te as default};";
if (!coreSource.endsWith(exportTail)) {
    throw new Error("highlight.js 核心的导出形式已变化，需要更新生成脚本");
}
const coreBody = coreSource.slice(0, -exportTail.length);

const languageDir = join(coreRoot, "languages");
const languageFiles = readdirSync(languageDir).filter((file) => file.endsWith(".min.js")).sort();
const languageSources = languageFiles.map((file) => {
    const source = readFileSync(join(languageDir, file), "utf8").trimEnd();
    if (!source.includes("hljs.registerLanguage(")) {
        throw new Error(`${file} 不是全局注册形式的语法文件`);
    }
    return source;
});
const zigSource = readFileSync(join(zigRoot, "dist/zig.min.js"), "utf8").trimEnd();

const protocol = `
self.onmessage = (event) => {
    const { id, language, source } = event.data;
    try {
        const result = hljs.highlight(source, { language, ignoreIllegals: true });
        self.postMessage({ id, html: result.value });
    } catch (error) {
        self.postMessage({ id, error: String(error && error.message ? error.message : error) });
    }
};
self.postMessage({ ready: true });
`;

const header = `/*!
 * foofoil 只读代码着色资源（离线、自包含，由 scripts/build-code-highlight-resources.mjs 生成，请勿手工编辑）
 * highlight.js ${HIGHLIGHT_VERSION}：BSD-3-Clause，版权归 Josh Goebel 与其他贡献者所有。
 * highlightjs-zig ${ZIG_VERSION}：MIT，版权归 Ash Ametrine 与 Amy Rose 所有。
 */`;

const bundle = [
    header,
    `var hljs = (function () {\n${coreBody}\nreturn te;\n})();`,
    ...languageSources,
    zigSource,
    protocol,
].join("\n");

// 在 Node 中以 Worker 相同的全局环境执行，确认注册数量与高亮结果。
const sandbox = {
    self: null,
    postMessage: () => {},
    console,
};
sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(bundle, sandbox, { filename: "highlight-worker.js" });
const registered = sandbox.hljs.listLanguages().sort();
if (registered.length !== EXPECTED_LANGUAGE_COUNT) {
    throw new Error(`注册语言数量为 ${registered.length}，期望 ${EXPECTED_LANGUAGE_COUNT}`);
}

const sample = sandbox.hljs.highlight("const x = 1; // note", { language: "javascript", ignoreIllegals: true }).value;
if (!sample.includes("hljs-keyword")) {
    throw new Error("高亮冒烟测试失败");
}

mkdirSync(outputDir, { recursive: true });
const workerPath = join(outputDir, "highlight-worker.js");
writeFileSync(workerPath, bundle + "\n");
const workerSHA256 = createHash("sha256").update(bundle + "\n").digest("hex");

const manifest = {
    highlightjs: { version: HIGHLIGHT_VERSION, license: "BSD-3-Clause", source: `https://www.npmjs.com/package/@highlightjs/cdn-assets/v/${HIGHLIGHT_VERSION}` },
    highlightjsZig: { version: ZIG_VERSION, license: "MIT", source: `https://www.npmjs.com/package/highlightjs-zig/v/${ZIG_VERSION}` },
    worker: { file: "highlight-worker.js", sha256: workerSHA256 },
    languages: registered,
};
writeFileSync(join(outputDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

console.log(`已生成 ${workerPath}`);
console.log(`注册语言 ${registered.length} 个，SHA-256 ${workerSHA256}`);
