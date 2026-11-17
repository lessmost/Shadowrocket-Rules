#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate Clash-Verge-Rev.yaml (Mihomo) from Shadowrocket.conf, so both keep the
# same proxy groups and rule order.
#
#   ruby scripts/build-mihomo-config.rb                  # rewrite Clash-Verge-Rev.yaml
#   ruby scripts/build-mihomo-config.rb --check          # fail if it is stale or invalid
#   ruby scripts/build-mihomo-config.rb IN.conf OUT.yaml # convert another variant

require "yaml"

module MihomoConfig
  PROVIDER = "my-subscription"
  PLACEHOLDER_URL = "https://your-subscription-url.example/replace-me"
  BUILTINS = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE].freeze
  QUIC = "(NETWORK,UDP),(DST-PORT,443)"
  QUIC_GUARDED_TYPES = %w[DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD RULE-SET].freeze
  RULE_TYPES = %w[
    DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD DOMAIN-REGEX DOMAIN-WILDCARD GEOSITE
    GEOIP SRC-GEOIP IP-ASN SRC-IP-ASN IP-CIDR IP-CIDR6 SRC-IP-CIDR IP-SUFFIX SRC-IP-SUFFIX
    SRC-PORT DST-PORT IN-PORT DSCP NETWORK UID
    PROCESS-NAME PROCESS-PATH PROCESS-NAME-REGEX PROCESS-PATH-REGEX
    PROCESS-NAME-WILDCARD PROCESS-PATH-WILDCARD IN-TYPE IN-USER IN-NAME
    AND OR NOT RULE-SET MATCH
  ].freeze
  BLACKMATRIX_SHADOWROCKET = %r{/blackmatrix7/ios_rule_script/[^/]+/rule/Shadowrocket/}

  module_function

  # Split "TYPE,PAYLOAD,TARGET,..." on top-level commas so logic-rule payloads stay intact.
  def split_rule(rule)
    parts = [+""]
    depth = 0
    rule.each_char do |char|
      depth += 1 if char == "("
      depth -= 1 if char == ")"
      if char == "," && depth.zero?
        parts << +""
      else
        parts.last << char
      end
    end
    parts
  end

  # { "General" => ["key = value", ...], "Rule" => [...], ... } without blanks or comments.
  def sections(text)
    result = Hash.new { |hash, key| hash[key] = [] }
    current = nil
    text.each_line(chomp: true) do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      if line.start_with?("[") && line.end_with?("]")
        current = line[1..-2]
      elsif current
        result[current] << line
      end
    end
    result
  end

  def key_values(lines)
    lines.to_h { |line| line.split("=", 2).map(&:strip) }
  end

  def list(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # Shadowrocket "*.example.com" becomes Mihomo "+.example.com" (domain and subdomains).
  def mihomo_domain(pattern)
    pattern.start_with?("*.") ? "+.#{pattern[2..]}" : pattern
  end

  # Shadowrocket's built-in PROXY selector holds every node; Mihomo needs it declared.
  def proxy_groups(lines)
    groups = [{ "name" => "PROXY", "type" => "select", "use" => [PROVIDER] }]
    lines.each do |line|
      name, spec = line.split("=", 2).map(&:strip)
      type, *items = list(spec)
      options = items.select { |item| item.include?("=") }.to_h { |item| item.split("=", 2) }
      members = items.reject { |item| item.include?("=") }
      groups << proxy_group(name, type, members, options)
    end
    groups
  end

  def proxy_group(name, type, members, options)
    case type
    when "select"
      default = options["policy-select-name"]
      members = [default] + (members - [default]) if default && members.include?(default)
      { "name" => name, "type" => "select", "proxies" => members }
    when "url-test"
      group = { "name" => name, "type" => "url-test", "use" => [PROVIDER] }
      group["filter"] = options["policy-regex-filter"] if options["policy-regex-filter"]
      group["url"] = options["url"] if options["url"]
      group["interval"] = Integer(options["interval"]) if options["interval"]
      group["tolerance"] = Integer(options["tolerance"]) if options["tolerance"]
      group["timeout"] = (Float(options["timeout"]) * 1000).round if options["timeout"]
      # Mihomo's default for a group with no matching node behaves like DIRECT.
      group["empty-fallback"] = "REJECT"
      group
    else
      raise ArgumentError, "unsupported proxy group type #{type.inspect} for #{name}"
    end
  end

  # Follow each select group's default member until it reaches a built-in policy.
  def proxied_by_default?(target, groups, seen = [])
    return false if %w[DIRECT REJECT REJECT-DROP].include?(target)

    group = groups[target]
    return true unless group && group["type"] == "select" && group["proxies"] && !seen.include?(target)

    proxied_by_default?(group["proxies"].first, groups, seen + [target])
  end

  # blackmatrix7 publishes every Shadowrocket list in Mihomo syntax under rule/Clash/.
  # Other lists stay as they are: Mihomo skips USER-AGENT and URL-REGEX lines with a warning.
  def rule_provider(type, url)
    name = File.basename(url, ".*").downcase.tr("_", "-")
    if url.match?(BLACKMATRIX_SHADOWROCKET)
      url = url.sub("/rule/Shadowrocket/", "/rule/Clash/")
      url = url.sub(/\.list\z/, ".yaml") if type == "DOMAIN-SET"
    end
    format = url.end_with?(".yaml") ? "yaml" : "text"
    provider = {
      "type" => "http",
      "url" => url,
      "path" => "./rules/#{name}.#{format == "yaml" ? "yaml" : "list"}",
      "interval" => 86_400,
      "behavior" => type == "DOMAIN-SET" ? "domain" : "classical",
      "format" => format
    }
    [name, provider]
  end

  def convert_rule(line, providers)
    parts = split_rule(line)
    case parts[0]
    when "RULE-SET", "DOMAIN-SET"
      name, provider = rule_provider(parts[0], parts[1])
      if providers.key?(name) && providers[name] != provider
        raise ArgumentError, "two rule sets map to provider #{name}"
      end

      providers[name] = provider
      ["RULE-SET", name, *parts[2..]].join(",")
    when "FINAL" then ["MATCH", *parts[1..]].join(",")
    when "AND", "OR", "NOT" then line.gsub("(PROTOCOL,", "(NETWORK,")
    else line
    end
  end

  # skip-proxy hosts bypass Shadowrocket entirely: route them DIRECT first and give
  # them real IPs. Patterns with an inner wildcard are covered by their suffix entry.
  def skip_proxy(value)
    rules = []
    fake_ip_filter = []
    list(value).each do |entry|
      if entry.match?(%r{\A[\d.]+/\d+\z})
        rules << "IP-CIDR,#{entry},DIRECT,no-resolve"
      elsif entry.start_with?("*.") && !entry[2..].include?("*")
        rules << "DOMAIN-SUFFIX,#{entry[2..]},DIRECT"
        fake_ip_filter << mihomo_domain(entry)
      elsif !entry.include?("*")
        rules << "DOMAIN,#{entry},DIRECT"
        fake_ip_filter << entry
      end
    end
    [rules, fake_ip_filter]
  end

  # Shadowrocket block-quic = all-proxy drops UDP/443 only for proxied traffic. Mihomo
  # cannot test the chosen exit, so guard each rule whose group defaults to a proxy.
  def rules(source, groups_by_name, skip_rules, providers)
    block_quic = key_values(source["General"])["block-quic"]
    result = skip_rules.dup
    result << "AND,(#{QUIC}),REJECT" if block_quic == "all"
    source["Rule"].each do |line|
      rule = convert_rule(line, providers)
      parts = split_rule(rule)
      target = parts[0] == "MATCH" ? parts[1] : parts[2]
      if block_quic == "all-proxy" && proxied_by_default?(target, groups_by_name)
        if parts[0] == "MATCH"
          result << "AND,(#{QUIC}),REJECT"
        elsif QUIC_GUARDED_TYPES.include?(parts[0])
          result << "AND,(#{QUIC},(#{parts[0]},#{parts[1]})),REJECT"
        end
      end
      result << rule
    end
    result.uniq
  end

  def dns(general, hosts, fake_ip_filter)
    policy = {}
    hosts.each do |domain, value|
      next unless value.start_with?("server:")

      server = value.delete_prefix("server:")
      policy[mihomo_domain(domain)] = server
      fake_ip_filter << mihomo_domain(domain) if server == "system"
    end
    nameservers = list(general["dns-server"]) + list(general["fallback-dns-server"])
    config = {
      "enable" => true,
      "ipv6" => general["ipv6"] == "true",
      "enhanced-mode" => "fake-ip",
      "fake-ip-range" => "198.18.0.1/16",
      "fake-ip-filter" => fake_ip_filter.uniq,
      "use-hosts" => true,
      "use-system-hosts" => true,
      "default-nameserver" => ["system"],
      "proxy-server-nameserver" => ["system"],
      # Shadowrocket "#proxy" sends the query through a proxy; here through the PROXY group.
      "nameserver" => nameservers.map { |server| server.sub(/#proxy\z/i, "#PROXY") }
    }
    config["direct-nameserver"] = ["system"] if general["dns-direct-system"] == "true"
    config["nameserver-policy"] = policy unless policy.empty?
    config
  end

  def build(text)
    source = sections(text)
    general = key_values(source["General"])
    hosts = key_values(source["Host"])
    groups = proxy_groups(source["Proxy Group"])
    skip_rules, fake_ip_filter = skip_proxy(general["skip-proxy"])
    providers = {}
    rule_list = rules(source, groups.to_h { |group| [group["name"], group] }, skip_rules, providers)

    config = {
      "mixed-port" => 7897,
      "allow-lan" => false,
      "mode" => "rule",
      "log-level" => "info",
      "ipv6" => general["ipv6"] == "true",
      "proxy-providers" => {
        PROVIDER => {
          "type" => "http",
          "url" => PLACEHOLDER_URL,
          "path" => "./proxy-providers/#{PROVIDER}.yaml",
          "interval" => 3600,
          "health-check" => { "enable" => true, "url" => "http://www.gstatic.com/generate_204", "interval" => 600 },
          # Like udp-policy-not-supported-behaviour = REJECT: without this, Mihomo sends UDP
          # for nodes that do not declare UDP support to a later rule, ending at DIRECT.
          "override" => { "udp" => true }
        }
      },
      "proxy-groups" => groups,
      "dns" => dns(general, hosts, fake_ip_filter),
      "hosts" => hosts.reject { |_domain, value| value.start_with?("server:") },
      # Restores domain names for connections to real IPs, such as fake-ip-filter hosts.
      "sniffer" => {
        "enable" => true,
        "force-dns-mapping" => true,
        "parse-pure-ip" => true,
        "override-destination" => false,
        "sniff" => {
          "HTTP" => { "ports" => [80, "8080-8880"] },
          "TLS" => { "ports" => [443, 8443] },
          "QUIC" => { "ports" => [443, 8443] }
        }
      },
      # Clash Verge Rev's TUN switch sets tun.enable. Hijacking every port 53 also
      # covers Shadowrocket's hijack-dns list.
      "tun" => {
        "stack" => "mixed",
        "auto-route" => true,
        "auto-detect-interface" => true,
        "dns-hijack" => ["any:53", "tcp://any:53"],
        "route-exclude-address" => list(general["tun-excluded-routes"])
      },
      "rule-providers" => providers,
      "rules" => rule_list
    }
    body = YAML.dump(config, line_width: -1).delete_prefix("---\n")
    # Psych escapes emoji as \UXXXXXXXX; write them literally so group names stay readable.
    body = body.gsub(/\\U(\h{8})/) { [Regexp.last_match(1).hex].pack("U") }
    raise "emoji unescaping changed the config" unless YAML.safe_load(body) == config

    header(source) + body
  end

  def header(source)
    omitted = ["URL Rewrite", "MITM"].select { |name| source.key?(name) }
    lines = [
      "# Generated from Shadowrocket.conf by scripts/build-mihomo-config.rb. Do not edit by hand.",
      "# Before importing into Clash Verge Rev, replace proxy-providers.#{PROVIDER}.url",
      "# with your own subscription URL. README.md lists the differences from Shadowrocket."
    ]
    lines << "# Not converted (no Mihomo equivalent): #{omitted.join(", ")}." unless omitted.empty?
    "#{lines.join("\n")}\n\n"
  end

  # Every reference the Mihomo core resolves at load time, checked statically.
  def problems(text)
    config = begin
      YAML.safe_load(text)
    rescue Psych::Exception => e
      return ["invalid YAML: #{e.message}"]
    end
    return ["top level is not a mapping"] unless config.is_a?(Hash)

    missing = %w[proxy-providers proxy-groups rule-providers rules dns].reject { |key| config.key?(key) }
    return missing.map { |key| "missing #{key}" } unless missing.empty?

    errors = []
    groups = config["proxy-groups"]
    names = groups.map { |group| group["name"] }
    errors << "duplicate proxy-group names" unless names.uniq.length == names.length
    policies = names + BUILTINS
    groups.each do |group|
      Array(group["use"]).each do |provider|
        errors << "#{group["name"]}: unknown proxy provider #{provider}" unless config["proxy-providers"].key?(provider)
      end
      Array(group["proxies"]).each do |member|
        errors << "#{group["name"]}: unknown member #{member}" unless policies.include?(member)
      end
    end

    providers = config["rule-providers"]
    paths = providers.values.map { |provider| provider["path"] }
    errors << "duplicate rule-provider paths" unless paths.uniq.length == paths.length
    providers.each do |name, provider|
      fields = %w[type url path interval behavior format].reject { |field| provider.key?(field) }
      errors << "rule provider #{name} lacks #{fields.join(", ")}" unless fields.empty?
    end

    config["rules"].each do |rule|
      parts = split_rule(rule)
      types = [parts[0]] + (%w[AND OR NOT].include?(parts[0]) ? parts[1].scan(/\(([A-Z][A-Z0-9-]*),/).flatten : [])
      unless types.all? { |type| RULE_TYPES.include?(type) }
        errors << "unsupported rule type: #{rule}"
        next
      end
      target = parts[0] == "MATCH" ? parts[1] : parts[2]
      errors << "unknown policy in: #{rule}" unless policies.include?(target)
      rule.scan(/RULE-SET,([^,()]+)/).flatten.each do |name|
        errors << "unknown rule provider #{name} in: #{rule}" unless providers.key?(name)
      end
    end
    errors << "last rule must be MATCH" unless config["rules"].last.to_s.start_with?("MATCH,")
    errors
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  args = ARGV.dup
  check = args.delete("--check")
  root = File.expand_path("..", __dir__)
  source = args[0] || File.join(root, "Shadowrocket.conf")
  output = args[1] || File.join(root, "Clash-Verge-Rev.yaml")

  yaml = MihomoConfig.build(File.read(source))
  errors = MihomoConfig.problems(yaml)
  abort("Generated config is invalid:\n#{errors.join("\n")}") unless errors.empty?

  if check
    abort("#{output} is out of date; run ruby scripts/build-mihomo-config.rb") unless File.exist?(output) && File.read(output) == yaml
    puts "#{output} is up to date"
  else
    File.write(output, yaml)
    puts "wrote #{output}"
  end
end
