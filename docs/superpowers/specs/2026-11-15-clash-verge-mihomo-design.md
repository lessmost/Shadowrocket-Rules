# Clash Verge Rev Mihomo 配置设计

## 意图

新增一份可被 Clash Verge Rev 导入的独立 Mihomo YAML 配置，让 Mac 用户继续使用本仓库维护的分流逻辑，同时从 Clash Verge Rev 已导入的订阅中自动获取代理节点。

## 目标

- 复现现有的地区节点组和主要服务分流：邮件、Google、AI、YouTube、Telegram、代码托管、Microsoft、Apple、香港银行和券商。
- 复用本仓库和外部仓库的远程规则集，并通过 Mihomo `rule-providers` 管理。
- 复现 Fastmail IMAP/SMTP 直连、国内服务直连、非中国流量和漏网之鱼的默认策略。
- 提供基础 DNS、fake-IP 和 TUN 配置，适用于 Clash Verge Rev 的 macOS 使用。
- 配置不包含任何私人节点或订阅内容，节点由 `proxy-providers.my-subscription` 从用户填入的订阅 URL 获得。

## 非目标

- 不修改或删除现有 Shadowrocket 配置。
- 不实现 Shadowrocket 的 HTTPS MITM 证书解密。
- 不承诺复现 `USER-AGENT`、完整 URL 匹配、URL Rewrite 等 Shadowrocket 专属行为。
- 不把用户节点写入仓库，也不依赖特定订阅名称。

## 约束与兼容性

- Mihomo 配置使用 YAML，规则顺序从上到下执行。
- `RULE-SET` 必须引用预先声明的 `rule-providers`。
- 本仓库的大多数 `.list` 是传统完整规则行，使用 `behavior: classical` 和 `format: text`；纯域名列表使用 `behavior: domain`。
- Shadowrocket 的 `DOMAIN-SET` 改为 Mihomo 的域名规则提供者。
- Shadowrocket 的 `FINAL` 改为 Mihomo 的 `MATCH`。
- Shadowrocket 的 `policy-regex-filter` 改为 proxy group 的 `filter`。
- `USER-AGENT` 和 `URL-REGEX` 没有直接的 Mihomo 等价物，相关少数规则不迁移；其余同一服务的域名规则继续生效。
- Shadowrocket 的 `hijack-dns`、`skip-proxy` 和 `tun-excluded-routes` 分别映射到 Mihomo DNS/TUN 配置；macOS 的 DNS 拦截能力需要在实际设备上验证。
- Shadowrocket 的 `block-quic = all-proxy` 以 UDP/443 拒绝规则近似实现。
- Clash Verge Rev 负责部分应用级 TUN 设置，配置文件只提供 Mihomo 支持的字段。

## 方案

### 方案一：独立完整 Mihomo 配置（已选择）

新增 `Clash-Verge-Rev.yaml`。它包含代理组、规则提供者、DNS、TUN 和完整规则链，并通过 `proxy-providers.my-subscription` 使用用户填入的节点订阅 URL。该文件可以独立保存、复制和导入，且不暴露节点信息；首次使用前需要替换示例 URL。

### 方案二：Clash Verge Rev 扩展配置

只提供覆盖订阅的扩展 YAML。它更适合绑定单个订阅，但不能脱离订阅作为完整配置使用，且订阅更新可能替换列表字段。

### 方案三：全部规则本地化为 Mihomo 专用格式

将所有规则转换为本地 YAML/MRS。运行时边界更稳定，但维护量更大，并且不能直接跟随外部规则源更新。

选择方案一，因为它最符合用户希望在 Mac 上独立使用本仓库规则的目标，同时保留远程规则更新和订阅节点的灵活性。

## 实现设计

实现时改为由 `scripts/build-mihomo-config.rb` 从 `Shadowrocket.conf` 生成 `Clash-Verge-Rev.yaml`，避免两份配置在后续修改中逐渐不一致；`--check` 检查生成结果是否过期。

- 新增 `PROXY` 选择组（包含订阅全部节点），对应 Shadowrocket 内置的 `PROXY`；其他策略组成员和顺序照搬，`policy-select-name` 指定的默认项排在第一位。
- 地区 `url-test` 组通过 `use: [my-subscription]` 取节点，`filter` 原样使用 `policy-regex-filter`（Mihomo 的 regexp2 支持其中的前瞻语法）；没有匹配节点时 `empty-fallback: REJECT`。
- blackmatrix7 规则集改用其 `rule/Clash/` 目录下的同名 Mihomo 格式版本；本仓库列表直接引用原文件，Mihomo 会跳过其中的 `USER-AGENT`、`URL-REGEX` 行。
- `skip-proxy` 转为最前面的 DIRECT 规则和 `fake-ip-filter`；`[Host]` 的 `server:` 条目转为 `nameserver-policy`，IP 条目转为 `hosts`；`dns-direct-system` 转为 `direct-nameserver: [system]`；`#proxy` 转为 `#PROXY`。
- `block-quic = all-proxy` 近似为：在默认走代理的规则前插入 UDP/443 拒绝规则。
- 订阅 provider 使用 `override: {udp: true}`，对应 `udp-policy-not-supported-behaviour = REJECT`，避免 UDP 落到 Mihomo 的直连兜底。
- 启用 sniffer，为 fake-ip-filter 中拿到真实 IP 的连接恢复域名。

## 验收标准

- YAML 可以被解析，顶层结构包含 `proxy-groups`、`rule-providers`、`rules`、`dns` 和 `tun`。
- 每个 `RULE-SET` 引用都存在对应的 `rule-provider`。
- 每个规则目标都对应一个内置策略或已定义的 proxy group。
- 配置不包含真实节点、密码、UUID、订阅 token 或其他私密信息。
- 静态检查确认未误用 Shadowrocket 的 `[General]`、`[Proxy Group]`、`DOMAIN-SET`、`FINAL` 等 INI 语法。

## 待实现事项

实现者需要完成 YAML 文件、必要的 README 使用说明和静态校验；若 Mihomo 实际版本对某字段有差异，应以 Clash Verge Rev 当前内置核心的校验结果为准，并在文档中标注调整。