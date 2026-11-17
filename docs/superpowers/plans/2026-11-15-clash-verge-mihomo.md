# Clash Verge Rev Mihomo Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent Mihomo YAML configuration that Clash Verge Rev can use with the user's imported subscription nodes while preserving the repository's main routing behavior.

**Architecture:** Keep the existing Shadowrocket files unchanged. Add one complete YAML profile that defines Mihomo proxy groups, remote rule providers, DNS/TUN settings, and an ordered rule chain; use a named `proxy-providers.my-subscription` placeholder so the profile consumes a user-supplied subscription URL without embedding private node data.

**Tech Stack:** Mihomo/Clash Meta YAML, remote HTTP rule providers, Ruby standard-library YAML parser for static validation, ripgrep-based reference checks.

**Spec:** `docs/superpowers/specs/2026-11-15-clash-verge-mihomo-design.md`

## Global Constraints

- 新增 `Clash-Verge-Rev.yaml`，不修改或删除现有 Shadowrocket 配置。
- 节点通过 `proxy-providers.my-subscription` 从用户填写的订阅 URL 获得，不写入私人节点、密码、UUID 或订阅 token。
- 规则提供者使用 Mihomo `type: http`，传统完整规则使用 `behavior: classical`，纯域名列表使用 `behavior: domain`。
- `DOMAIN-SET` 改为规则提供者加 `RULE-SET`，`FINAL` 改为 `MATCH`，`policy-regex-filter` 改为 proxy group 的 `filter`。
- 不伪造 `USER-AGENT`、`URL-REGEX`、URL Rewrite 或 MITM 的等价行为；在配置注释和 README 中说明限制。
- 不提交 git commit，除非用户另行要求。

## Review Focus

- 节点订阅为空或节点名称不含地区关键词时，配置仍能加载且主组保留 DIRECT/REJECT 等基础选项。
- 规则提供者 URL、`behavior` 和 `format` 不匹配时，配置可能加载但规则失效；静态检查必须覆盖每个 `RULE-SET` 引用。
- 代理组名称含中文、emoji 或空格时，所有规则目标必须与定义完全一致。
- DNS/TUN 字段在 macOS 上可能由 Clash Verge Rev 应用设置覆盖；README 必须说明启用 TUN 后验证 DNS 拦截效果。
- Shadowrocket 专属规则若被原样复制，Mihomo 会拒绝或忽略；静态检查必须阻止 `[General]`、`DOMAIN-SET`、`FINAL` 等旧语法残留。

---

### Task 1: Add the independent Mihomo profile skeleton and proxy groups

**Files:**
- Create: `Clash-Verge-Rev.yaml`

**Interfaces:**
- Produces the top-level Mihomo profile consumed by Tasks 2–4.
- Defines exact policy group names: `🚀 节点选择`, `🇭🇰 香港节点`, `🇹🇼 台湾节点`, `🇯🇵 日本节点`, `🇸🇬 新加坡节点`, `🇺🇸 美国节点`, `🌐 其他节点`, and each service policy group used by the rule chain.

- [ ] **Step 1: Write the top-level profile sections**

Add `mixed-port`, `allow-lan`, `mode`, `log-level`, `ipv6`, `proxies`, `proxy-groups`, `dns`, `tun`, `rule-providers`, and `rules` placeholders. Keep `proxies` empty so imported subscription nodes remain the source of outbound proxies.

- [ ] **Step 2: Define subscription-backed proxy groups**

Define `proxy-providers.my-subscription` with a clearly marked placeholder URL. Use `use: [my-subscription]` for the main and regional groups. Use `type: select` for manual service policies and `type: url-test` with the existing gstatic health URL and 600-second interval for regional groups. Translate each current region regex to Mihomo `filter`; make `🌐 其他节点` exclude all recognized region keywords.

- [ ] **Step 3: Verify group names and fallback references**

Run a text check that every group referenced by another group is one of the declared group names or Mihomo built-ins `DIRECT`/`REJECT`. Confirm no `PROXY` placeholder remains, because imported Mihomo profiles do not guarantee a built-in `PROXY` group.

Expected result: the profile has a complete proxy-group graph that works even when no regional node matches.

---

### Task 2: Convert repository and external lists to Mihomo rule providers

**Files:**
- Modify: `Clash-Verge-Rev.yaml`

**Interfaces:**
- Consumes the rule source URLs currently referenced in `Shadowrocket.conf`.
- Produces named providers used by the `rules` section, with unique local cache paths and matching `behavior`/`format`.

- [ ] **Step 1: Add classical providers**

Declare HTTP text providers for `BlockHttpDNS`, `Mail`, `Google`, `AI`, `YouTube`, `BiliBili`, `Lan`, `Telegram`, `GitHub`, `GitLab`, `Atlassian`, `Microsoft`, `HSBC_HK`, `HK_Banks_Direct`, `HK_Broker`, `ApplePush`, `Apple`, `China`, and `Global`. Use `behavior: classical` because these sources contain full rule lines such as `DOMAIN-SUFFIX` and `IP-CIDR`.

- [ ] **Step 2: Add domain providers for domain-only lists**

Declare text providers for Apple, China, and Global domain-only list URLs where applicable, using distinct provider names and `behavior: domain`. Do not use Shadowrocket `DOMAIN-SET` syntax in the final rules.

- [ ] **Step 3: Check provider coverage**

Compare all `RULE-SET` names in the planned rule chain against the provider keys. Ensure each provider has `type`, `url`, `path`, `interval`, `behavior`, and `format`, and that no provider path is duplicated.

Expected result: every remote rule source has an explicit Mihomo provider definition with a compatible behavior.

---

### Task 3: Rebuild the ordered routing and DNS/TUN behavior

**Files:**
- Modify: `Clash-Verge-Rev.yaml`

**Interfaces:**
- Consumes proxy group names from Task 1 and provider names from Task 2.
- Produces the final ordered `rules`, `dns`, and `tun` sections.

- [ ] **Step 1: Add DNS and TUN settings**

Configure IPv4-only fake-IP DNS, Cloudflare and Google DoH resolvers, local/private fake-IP exclusions, `use-hosts`, local host mappings, and TUN route exclusions for private/reserved networks. Add supported Mihomo DNS hijack entries and leave application-owned settings documented by comments.

- [ ] **Step 2: Add high-priority direct and protocol rules**

Keep `localhost.weixin.qq.com`, local reverse-DNS suffixes, Doubao, DeepSeek, Apple TCP/5223, Bilibili HTTPDNS/IP exceptions, and Fastmail direct rules before broad rule providers. Express QUIC blocking as a Mihomo UDP/443 reject rule.

- [ ] **Step 3: Add provider-backed service rules in repository order**

Reference the providers in the same priority order as the current Shadowrocket files: HTTPDNS protection, mail, YouTube translation, Google, AI, YouTube, BiliBili, LAN, Telegram, code hosting, Microsoft, HSBC, Hong Kong banks, brokers, Apple Push, Apple, China, and Global.

- [ ] **Step 4: Add domestic and final fallback rules**

End with `GEOIP,CN,🔒 国内服务` and `MATCH,🐟 漏网之鱼`. Ensure every policy name is declared and every broad rule appears after the specific service rules.

- [ ] **Step 5: Document intentional omissions in YAML comments**

State that Apple `USER-AGENT`, bank `URL-REGEX`, Shadowrocket URL Rewrite, and MITM are not represented because Mihomo has no direct equivalent in this profile.

Expected result: the YAML has a complete, ordered routing chain with documented approximations and no Shadowrocket-only section syntax.

---

### Task 4: Add user-facing usage notes and validate the generated profile

**Files:**
- Modify: `README.md`
- Create: `scripts/validate-mihomo-config.rb` (only if a reusable validator is needed)

**Interfaces:**
- README tells the user how to import `Clash-Verge-Rev.yaml` into Clash Verge Rev and what behavior differs from Shadowrocket.
- Validator accepts the YAML path as its first argument and exits nonzero with a concise error for malformed YAML, undeclared rule providers, undeclared policy targets, or Shadowrocket-only syntax.

- [ ] **Step 1: Add README migration instructions**

Document the raw URL for `Clash-Verge-Rev.yaml`, the requirement to import a node subscription separately, the profile import flow, the TUN/DNS verification step on macOS, and the four known compatibility differences.

- [ ] **Step 2: Validate YAML syntax**

Run Ruby's standard YAML parser against `Clash-Verge-Rev.yaml` and confirm the top-level object is a mapping containing `proxy-groups`, `rule-providers`, and `rules`.

- [ ] **Step 3: Validate rule/provider/group references**

Use the validator or a deterministic shell check to confirm each `RULE-SET` provider exists, each rule policy is a built-in or declared group, each provider path is unique, and no prohibited Shadowrocket section or rule token remains.

- [ ] **Step 4: Review the diff and working tree**

Run `git diff --check`, inspect the generated YAML and README changes, and report any fields that require verification against the exact Mihomo core bundled by the user's Clash Verge Rev version.

Expected result: a standalone profile, instructions, and repeatable static checks are present without exposing private node information.
